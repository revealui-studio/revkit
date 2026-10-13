import importlib.util
import json
import multiprocessing
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'shell/bin/work-services.py'
spec = importlib.util.spec_from_file_location('manager', SOURCE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
PROJECTS = [{'root': '/projects/' + n, 'container': n, 'compose_project': n} for n in ('a', 'b')]

class Backend:
    def __init__(self, after_stop=lambda: None):
        self.running = {'a', 'b'}
        self.ids = {'a': 'id-a', 'b': 'id-b'}
        self.busy = False
        self.stopped = []
        self.after_stop = after_stop
    def run(self, args, timeout=15):
        if args[:2] == ['docker', 'ps']:
            return '\n'.join(self.ids if '--all' in args else self.running)
        if args[:2] == ['docker', 'inspect']:
            name = args[2]
            return json.dumps([{'Id': self.ids[name], 'Config': {'Labels': {'com.docker.compose.project': name, 'com.docker.compose.service': 'postgres'}}, 'NetworkSettings': {'Ports': {}}}])
        if args[:2] == ['docker', 'stop']:
            self.stopped.append(args[-1])
            name = next(n for n, identity in self.ids.items() if identity == args[-1])
            self.running.remove(name)
            self.after_stop()
            return ''
        if args == ['sudo', '-n', 'systemctl', 'stop', 'docker.service']:
            return ''
        raise AssertionError(args)

def tick(directory, backend, through_main=False):
    state = Path(directory)
    (state/'idle.json').write_text(json.dumps({'a': 0, 'b': 0}))
    with patch.object(m, 'STATE', state), patch.object(m, 'docker_active', return_value=True), patch.object(m, 'run', side_effect=backend.run), patch.object(m, 'clients_busy', return_value=False), patch.object(m, 'database_clients_busy', side_effect=lambda _: backend.busy):
        if through_main:
            with patch.object(m, "CONFIG", state/"config.json"), patch.object(sys, "argv", ["manager", "tick"]):
                m.main()
        else:
            m.tick(PROJECTS)

class Races(unittest.TestCase):
    def test_new_client_after_first_stop_preserves_second_database(self):
        backend = Backend()
        backend.after_stop = lambda: setattr(backend, 'busy', True)
        with tempfile.TemporaryDirectory() as directory:
            tick(directory, backend)
        self.assertEqual(backend.stopped, ['id-a'])
        self.assertIn('b', backend.running)

    def test_replacement_after_first_stop_is_not_stopped(self):
        backend = Backend()
        backend.after_stop = lambda: backend.ids.update(b='foreign-replacement')
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, 'identity changed'):
                tick(directory, backend)
        self.assertEqual(backend.stopped, ['id-a'])

    def test_direct_ipv4_and_ipv6_database_connections_block_cleanup(self):
        details = [{'NetworkSettings': {'Ports': {'5432/tcp': [{'HostPort': '55432'}]}, 'Networks': {'bridge': {'IPAddress': '172.17.0.2', 'GlobalIPv6Address': 'fd00::2'}}}}]
        for endpoint in ['172.17.0.2:5432', '[fd00::2]:5432', 'fd00::2:5432']:
            with self.subTest(endpoint=endpoint), patch.object(m, 'run', side_effect=[json.dumps(details), '0 0 127.0.0.1:42000 '+endpoint]):
                self.assertTrue(m.database_clients_busy([PROJECTS[0]]))

    def test_enter_writes_lease_while_real_tick_process_waits_in_stop(self):
        # Real cross-process flock: the tick stays stalled until entry succeeds.
        started, release = multiprocessing.Event(), multiprocessing.Event()
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            config = state/'config.json'
            config.write_text(json.dumps({'projects': PROJECTS}))
            backend = Backend()
            def wait():
                started.set()
                if not release.wait(10):
                    raise RuntimeError('test stop timed out')
            backend.after_stop = wait
            def cleanup():
                tick(directory, backend, through_main=True)
            worker = multiprocessing.Process(target=cleanup)
            worker.start()
            try:
                self.assertTrue(started.wait(5))
                code = '''import importlib.util,sys
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('m',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.STATE=Path(sys.argv[2]);m.CONFIG=m.STATE/'config.json'
sys.argv=['manager','enter','--session','incoming','--pid',sys.argv[3],'--work-dir','/projects/b']
with patch.object(m.subprocess,'Popen',lambda *a,**k:None):m.main()
'''
                subprocess.run(['python3', '-c', code, str(SOURCE), directory, str(os.getpid())], check=True, timeout=3)
                leases = list(state.glob('lease-*.json'))
                self.assertEqual(len(leases), 1)
                self.assertEqual(json.loads(leases[0].read_text())['pid'], os.getpid())
            finally:
                release.set()
                worker.join(5)
                if worker.is_alive():
                    worker.terminate(); worker.join()
            self.assertEqual(worker.exitcode, 0)

if __name__ == '__main__':
    unittest.main()
