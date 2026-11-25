"""Cold-container v1 worker engine. No CLI admission, discovery, installs or key creation.

The controller must hold its Windows source lease until FINAL (or confirmed ABORT).
A caller stopping wsl.exe without either acknowledgment MUST retain custody and
reconcile the durable journal; parent exit is not Linux termination evidence.
"""
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import queue
import selectors
import signal
import stat
import struct
import subprocess
import threading
import time
import uuid

PROFILE = 'cold-vhd-container-v1'
PROTOCOL = 'revkit-cold-worker-v1'
BORG_SHA256 = 'c8457f70660064d0f45b38283ab4cc65b342970012013201d3aec713a75898fb'
MAX_DATA = 65536
MAX_CONTROL = 16384
LIMITS = {b'R': MAX_CONTROL, b'S': 1024, b'D': MAX_DATA, b'E': MAX_CONTROL,
          b'H': 0, b'C': 0, b'K': MAX_CONTROL, b'A': MAX_CONTROL, b'Z': MAX_CONTROL,
          b'F': MAX_CONTROL}


class Refused(Exception):
    """Messages are fixed codes. Never forward a child exception/diagnostic."""


def encode(kind, payload=b''):
    if kind not in LIMITS or len(payload) > LIMITS[kind]:
        raise Refused('frame-bound')
    return kind + struct.pack('<I', len(payload)) + payload


def document(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def parse(payload):
    def pairs(rows):
        result = {}
        for key, value in rows:
            if key in result:
                raise Refused('duplicate-control-field')
            result[key] = value
        return result
    try:
        value = json.loads(payload.decode('utf-8'), object_pairs_hook=pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(Refused('control-number')))
        if not isinstance(value, dict):
            raise Refused('control-object')
        return value
    except (ValueError, UnicodeError, RecursionError):
        raise Refused('control-json') from None


def exact(value, fields):
    if set(value) != set(fields):
        raise Refused('control-fields')


def sha(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def request(payload, binding):
    value = parse(payload)
    exact(value, ('protocol', 'profile', 'transactionId', 'archiveId', 'phase', 'bindingSha256', 'bytes', 'sha256'))
    try:
        if any(str(uuid.UUID(value[k])) != value[k] for k in ('transactionId', 'archiveId')):
            raise ValueError()
    except (ValueError, TypeError, AttributeError):
        raise Refused('transaction-uuid') from None
    if (value['protocol'] != PROTOCOL or value['profile'] != PROFILE or
            value['phase'] not in ('backup', 'restore') or
            (value['phase'] == 'backup' and value['archiveId'] != value['transactionId']) or value['bindingSha256'] != binding or
            type(value['bytes']) is not int or not 0 < value['bytes'] <= 2**63-1 or
            not sha(value['sha256'])):
        raise Refused('request-binding')
    return value


class Receiver:
    """One bounded reader; EOF is a control failure, never archive completion."""
    def __init__(self, fd, timeout):
        self.fd, self.timeout = fd, timeout
        self.items = queue.Queue(2)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _bytes(self, size):
        result = bytearray()
        deadline = time.monotonic() + self.timeout
        while len(result) < size:
            if self.stop.is_set():
                raise Refused('receiver-stopped')
            ready, _, _ = __import__('select').select([self.fd], [], [], min(.1, max(0, deadline-time.monotonic())))
            if time.monotonic() >= deadline:
                raise Refused('control-timeout')
            if ready:
                data = os.read(self.fd, size-len(result))
                if not data:
                    raise Refused('control-eof')
                result.extend(data)
        return bytes(result)

    def _put(self, item):
        while not self.stop.is_set():
            try:
                self.items.put(item, timeout=.1)
                return
            except queue.Full:
                pass

    def _read(self):
        try:
            while not self.stop.is_set():
                header = self._bytes(5)
                kind, size = header[:1], struct.unpack('<I', header[1:])[0]
                if kind not in LIMITS or size > LIMITS[kind]:
                    raise Refused('frame-bound')
                self._put((kind, self._bytes(size) if size else b''))
        except Refused as exc:
            self._put(exc)
        except OSError:
            self._put(Refused('control-io'))

    def next(self, wait=0):
        try:
            item = self.items.get(timeout=wait)
        except queue.Empty:
            return None
        if isinstance(item, Refused):
            raise item
        if item[0] == b'C':
            raise Refused('controller-cancelled')
        return item

    def close(self):
        self.stop.set()
        self.thread.join(2)
        if self.thread.is_alive():
            raise Refused('receiver-exit-unconfirmed')


def private_directory(path):
    path = Path(path)
    if not path.is_absolute() or path.resolve() != path:
        raise Refused('canonical-private-directory')
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise Refused('private-directory-owner-mode')
    return path


def synced_file(directory, name, value):
    fd = os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(document(value) + b'\n')
            stream.flush()
            os.fsync(stream.fileno())
        dfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except BaseException:
        # An incomplete receipt remains evidence; never overwrite or unlink it.
        raise


class Session:
    """Deployment-internal capability; never constructed from wire paths/commands.

    Real admission is intentionally not supplied by this module. The Windows
    wrapper remains closed. Tests construct this engine only for NEW private
    synthetic repositories. No wire flag can grant that capability.
    """
    def __init__(self, binary, repository, state, binding, *, timeout=120, idle=10):
        self.binary = Path(binary)
        self.repository = private_directory(repository)
        self.state = private_directory(state)
        if self.repository == self.state or self.repository in self.state.parents or self.state in self.repository.parents:
            raise Refused('overlapping-custody')
        if not sha(binding) or not 1 <= idle <= timeout <= 86400:
            raise Refused('session-bound')
        self.binding, self.timeout, self.idle = binding, timeout, idle
        self.children = []
        self.group_gone = True
        self.deadline = 0
        self.tx = None
        self.sequence = 0

    def tool(self):
        if self.binary.resolve() != self.binary:
            raise Refused('tool-canonical')
        fd = os.open(self.binary, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o022:
                raise Refused('tool-mode')
            with os.fdopen(os.dup(fd), 'rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            if digest != BORG_SHA256:
                raise Refused('tool-sha256')
        finally:
            os.close(fd)
        # Hash pin is the reviewed signed-release identity. Production still needs
        # immutable owner/path/interpreter admission to exclude replacement races.

    def event(self, phase, **values):
        self.sequence += 1
        synced_file(self.tx, f'{self.sequence:03d}-{phase}.json', dict(phase=phase, **values))

    def _group_absent(self, child):
        # Reap ONLY adopted descendants of this owned process group. Borg's
        # standalone bootloader forks; waiting only on its parent is insufficient.
        deadline = time.monotonic()+5
        while True:
            try:
                while os.waitpid(-child.pid, os.WNOHANG)[0]:
                    pass
            except ChildProcessError:
                pass
            try:
                os.killpg(child.pid, 0)
            except ProcessLookupError:
                return
            if time.monotonic() >= deadline:
                self.group_gone = False
                raise Refused('linux-group-exit-unconfirmed')
            time.sleep(.02)

    def _stop_child(self, child):
        # This process group belongs ONLY to this child (start_new_session=True).
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.group_gone = False
            raise Refused('linux-child-exit-unconfirmed') from None
        self._group_absent(child)

    def run(self, args, rx, secret_fd, source=None, output=None):
        env = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'HOME': str(self.tx),
               'BORG_CACHE_DIR': str(self.tx/'cache'), 'BORG_SECURITY_DIR': str(self.tx/'security'),
               'BORG_CONFIG_DIR': str(self.tx/'config'), 'TMPDIR': str(self.tx),
               'BORG_PASSPHRASE_FD': str(secret_fd), 'BORG_EXIT_CODES': 'modern'}
        os.lseek(secret_fd, 0, os.SEEK_SET)
        # Process-local Linux lifetime ownership, no account/service/security-policy change.
        # A dedicated worker must adopt/reap the pinned standalone Borg's orphaned children.
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
            raise Refused('linux-subreaper-unavailable')
        child = subprocess.Popen([str(self.binary), '--lock-wait=1', *args],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 cwd=self.tx, env=env, pass_fds=(secret_fd,), start_new_session=True)
        self.children.append(child.pid)
        pending = b''
        source_done = source is None
        diagnostics = 0
        selector = selectors.DefaultSelector()
        for pipe, label in ((child.stdin, 'in'), (child.stdout, 'out'), (child.stderr, 'err')):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_WRITE if label == 'in' else selectors.EVENT_READ, label)
        try:
            while selector.get_map() or child.poll() is None:
                if time.monotonic() > self.deadline:
                    raise Refused('transaction-timeout')
                if source is None:
                    item = rx.next()
                    if item and item[0] != b'H':
                        raise Refused('unexpected-control')
                for key, _ in selector.select(.05):
                    pipe, label = key.fileobj, key.data
                    if label == 'in':
                        if not pending and not source_done:
                            item = rx.next()
                            if item:
                                if item[0] == b'H':
                                    continue
                                pending, source_done = source(item)
                        if pending:
                            try:
                                sent = os.write(pipe.fileno(), pending)
                                pending = pending[sent:]
                            except BlockingIOError:
                                pass
                        if not pending and source_done:
                            selector.unregister(pipe)
                            pipe.close()
                    else:
                        data = os.read(pipe.fileno(), MAX_DATA)
                        if not data:
                            selector.unregister(pipe)
                            pipe.close()
                        elif label == 'err':
                            diagnostics += len(data)
                            if diagnostics > MAX_DATA:
                                raise Refused('diagnostic-bound')
                        elif output:
                            output(data)
                        else:
                            raise Refused('unexpected-child-output')
            child.wait(timeout=1)
            # Even normal exit must prove the owned Linux process group absent.
            self._group_absent(child)
            if child.returncode != 0 or diagnostics:
                raise Refused('borg-exit-or-diagnostics')
        except BaseException:
            self._stop_child(child)
            raise
        finally:
            selector.close()
            for pipe in (child.stdin, child.stdout, child.stderr):
                pipe.close()

    def serve(self, incoming_fd, outgoing_fd):
        """Duplex framed binary transaction; fixed Borg commands, no shell.

        Success requires E (source digest), A (readback), K (controller verified
        readback under its lease), then Z (fsynced commit + no Linux group).
        C/EOF/idle/failure returns F ONLY after teardown, never Z. The controller
        must classify missing F/Z as lifetime unconfirmed, not safe cancellation.
        """
        rx = Receiver(incoming_fd, self.idle)
        output_flags = fcntl.fcntl(outgoing_fd, fcntl.F_GETFL)
        os.set_blocking(outgoing_fd, False)
        lock_fd = secret_fd = None
        req = None
        self.deadline = time.monotonic() + self.timeout
        def emit(kind, payload=b''):
            data = memoryview(encode(kind, payload))
            while data:
                if time.monotonic() > self.deadline:
                    raise Refused('transaction-timeout')
                _, ready, _ = __import__('select').select([], [outgoing_fd], [], .1)
                if ready:
                    try:
                        count = os.write(outgoing_fd, data)
                        data = data[count:]
                    except BlockingIOError:
                        pass
        def receive(kind):
            while time.monotonic() <= self.deadline:
                item = rx.next(.1)
                if item and item[0] != b'H':
                    if item[0] != kind:
                        raise Refused('control-order')
                    return item[1]
            raise Refused('transaction-timeout')
        try:
            req = request(receive(b'R'), self.binding)
            # Validate before creating a transaction, opening a repository lock or executing a tool.
            self.tool()
            lock_fd = os.open(self.state/'worker.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            info = os.fstat(lock_fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
                raise Refused('worker-lock-custody')
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Refused('worker-busy') from None
            self.tx = self.state/req['transactionId']
            self.tx.mkdir(mode=0o700)  # Existing attempts can never be reused/overwritten.
            self.event('pending', request=req, productionAccepted=False)
            secret = receive(b'S')
            if not secret or b'\x00' in secret or b'\n' in secret or b'\r' in secret:
                raise Refused('secret-descriptor-input')
            secret_fd = os.memfd_create('revkit-private-input', os.MFD_CLOEXEC)
            os.fchmod(secret_fd, 0o600)
            os.write(secret_fd, secret + b'\n')
            del secret
            archive = str(self.repository)+'::cold-'+req['archiveId']
            count, digest = 0, hashlib.sha256()
            def source(item):
                nonlocal count
                kind, data = item
                if kind == b'D' and data:
                    count += len(data)
                    if count > req['bytes']:
                        raise Refused('source-excess')
                    digest.update(data)
                    return data, False
                if kind == b'E':
                    end = parse(data)
                    exact(end, ('bytes', 'sha256'))
                    if type(end['bytes']) is not int or end != {'bytes': count, 'sha256': digest.hexdigest()} or count != req['bytes'] or digest.hexdigest() != req['sha256']:
                        raise Refused('source-length-or-digest')
                    return b'', True
                raise Refused('source-frame')
            if req['phase'] == 'backup':
                self.run(['create', '--chunker-params=fixed,4194304', '--files-cache=disabled',
                          '--compression=none', '--stdin-name=ext4.vhdx', archive, '-'], rx, secret_fd, source=source)
                # Successful Borg create alone cannot admit a truncated producer.
                if count != req['bytes'] or digest.hexdigest() != req['sha256']:
                    raise Refused('source-not-complete')
                self.event('archive-created', bytes=count, sha256=digest.hexdigest())
            else:
                # Restore is an exact named archive, never latest/list/auto-selection.
                # Request transactionId identifies that archive. Fresh state is required.
                end = parse(receive(b'E'))
                exact(end, ('bytes', 'sha256'))
                if type(end['bytes']) is not int or end != {'bytes': 0, 'sha256': hashlib.sha256(b'').hexdigest()}:
                    raise Refused('restore-input')
            self.run(['check', '--verify-data', str(self.repository)], rx, secret_fd)
            self.event('archive-checked')
            restored_count, restored_hash = 0, hashlib.sha256()
            def output(data):
                nonlocal restored_count
                restored_count += len(data)
                if restored_count > req['bytes']:
                    raise Refused('restored-excess')
                restored_hash.update(data)
                emit(b'D', data)
            self.run(['extract', '--stdout', archive, 'ext4.vhdx'], rx, secret_fd, output=output)
            if restored_count != req['bytes'] or restored_hash.hexdigest() != req['sha256']:
                raise Refused('restored-length-or-digest')
            receipt = dict(protocol=PROTOCOL, profile=PROFILE, transactionId=req['transactionId'],
                           phase=req['phase'], archiveId=req['archiveId'], bindingSha256=self.binding, bytes=restored_count,
                           sha256=restored_hash.hexdigest(), toolSha256=BORG_SHA256,
                           linuxChildrenExited=True, savingsCreditBytes=0, productionAccepted=False)
            self.event('readback', receipt=receipt)
            emit(b'A', document(receipt))
            commit = parse(receive(b'K'))
            if commit != {'receiptSha256': hashlib.sha256(document(receipt)).hexdigest()}:
                raise Refused('controller-commit-binding')
            # Final receipt is fsynced before acknowledgment; source lease must still be held.
            self.event('committed', receipt=receipt)
            emit(b'Z', document(receipt))
            return receipt
        except BaseException as exc:
            code = str(exc) if isinstance(exc, Refused) else 'worker-refused'
            failure = dict(protocol=PROTOCOL, transactionId=req['transactionId'] if req else None,
                           bindingSha256=self.binding, code=code, linuxChildrenExited=self.group_gone,
                           productionAccepted=False)
            if self.tx and self.tx.exists():
                self.event('failed', receipt=failure)
            # A bounded failure acknowledgment has its own teardown/communication budget.
            self.deadline = time.monotonic()+2
            try:
                emit(b'F', document(failure))
            except (Refused, OSError):
                pass
            raise Refused(code) from None
        finally:
            if secret_fd is not None:
                os.close(secret_fd)
            if lock_fd is not None:
                os.close(lock_fd)
            rx.close()
            fcntl.fcntl(outgoing_fd, fcntl.F_SETFL, output_flags)
