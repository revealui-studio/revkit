import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import stat
import sys
import tempfile
import tomllib
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
SPEC = importlib.util.spec_from_file_location('shell_actions', ROOT / 'scripts/codex-shell-config.py')
ADAPTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADAPTER)
from codex_adapter_lib import Refused


class ReviewedRetirementRenderingTests(unittest.TestCase):
    def test_only_reviewed_field_is_removed_in_explicit_inline_and_dotted_forms(self):
        for entry in ['[shell_environment_policy.set]\nBASH_ENV="~/.config/shell/env.sh"\nOWNER="sentinel"\n',
                      'set={BASH_ENV="~/.config/shell/env.sh",OWNER="sentinel"}\n',
                      'set.BASH_ENV="~/.config/shell/env.sh"\nset.OWNER="sentinel"\n']:
            with self.subTest(entry=entry):
                text = 'model="owner-choice"\n[shell_environment_policy]\ninherit="core"\n' + entry
                result = ADAPTER.render_reviewed_startup_retirement(text, ADAPTER.REVIEWED_BASH_ENV)
                before, after = tomllib.loads(text), tomllib.loads(result)
                del before['shell_environment_policy']['set']['BASH_ENV']
                self.assertEqual(before, after)

    def test_unknown_value_or_other_startup_override_is_refused(self):
        for entry in ['BASH_ENV="/srv/owner/custom.sh"', 'bash_env="~/.config/shell/env.sh"',
                      'BASH_ENV="~/.config/shell/env.sh"\nENV="owner"',
                      'BASH_ENV="~/.config/shell/env.sh"\nNODE_OPTIONS="owner"']:
            with self.subTest(entry=entry), self.assertRaises(Refused):
                ADAPTER.render_reviewed_startup_retirement('[shell_environment_policy]\ninherit="core"\n[shell_environment_policy.set]\n'+entry+'\n', ADAPTER.REVIEWED_BASH_ENV)

    def test_ordinary_runtime_action_does_not_admit_session_or_startup_values(self):
        for name in ['XDG_RUNTIME_DIR', 'DBUS_SESSION_BUS_ADDRESS', 'BASH_ENV', 'SSH_AUTH_SOCK', 'PATH', 'NODE_OPTIONS']:
            with self.subTest(name=name), self.assertRaises(Refused):
                ADAPTER.render('[shell_environment_policy]\ninherit="core"\n', {name:'/srv/unreviewed'}, 'linux')


@unittest.skipUnless(sys.platform.startswith('linux'), 'native reviewed shell actions require Linux')
class NativeShellActionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.home = self.base/'home'
        self.config = self.home/'.codex/config.toml'
        self.config.parent.mkdir(parents=True, mode=0o700)
        self.initial = b'# owner\r\nmodel="owner-choice"\r\napproval_policy="on-request"\r\n[shell_environment_policy]\r\ninherit="core"\r\nignore_default_excludes=false\r\n[shell_environment_policy.set]\r\nBASH_ENV="~/.config/shell/env.sh"\r\nOWNER_SECRET="synthetic-sentinel"\r\n'
        self.config.write_bytes(self.initial)
        self.config.chmod(0o600)
        self.runtime = self.base/'runtime'
        self.runtime.mkdir(mode=0o700)
        self.bus = self.runtime/'bus'
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.bus))
        self.listener.listen(32)
        self.addCleanup(self.listener.close)
        home_patch = patch.object(ADAPTER.Path, 'home', return_value=self.home)
        home_patch.start(); self.addCleanup(home_patch.stop)
        session_patch = patch.object(ADAPTER, 'native_session_binding', side_effect=lambda: ADAPTER.verify_native_session(self.runtime, os.getuid()))
        session_patch.start(); self.addCleanup(session_patch.stop)

    def project(self):
        preview = ADAPTER.project_native_session(self.config, 'linux')
        return ADAPTER.project_native_session(self.config, 'linux', apply=True, reviewed_sha256=preview['before_sha256'])

    def test_sequence_preserves_owner_settings_and_exact_backups(self):
        projected_plan = ADAPTER.project_native_session(self.config, 'linux')
        self.assertFalse(projected_plan['applied'])
        self.assertEqual(self.config.read_bytes(), self.initial)
        self.project()
        projected_bytes = self.config.read_bytes()
        projected = tomllib.loads(projected_bytes.decode())
        self.assertEqual(projected['shell_environment_policy']['set']['BASH_ENV'], ADAPTER.REVIEWED_BASH_ENV)
        plan = ADAPTER.retire_reviewed_startup(self.config, ADAPTER.REVIEWED_BASH_ENV, 'linux')
        self.assertFalse(plan['applied'])
        self.assertEqual(self.config.read_bytes(), projected_bytes)
        result = ADAPTER.retire_reviewed_startup(self.config, ADAPTER.REVIEWED_BASH_ENV, 'linux', apply=True, reviewed_sha256=plan['before_sha256'])
        after = tomllib.loads(self.config.read_text())
        del projected['shell_environment_policy']['set']['BASH_ENV']
        self.assertEqual(after, projected)
        self.assertEqual(result['after_sha256'], hashlib.sha256(self.config.read_bytes()).hexdigest())
        backups = [p.read_bytes() for p in self.config.parent.glob('config.toml.revkit-before-*')]
        self.assertIn(self.initial, backups)
        self.assertIn(projected_bytes, backups)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(after['shell_environment_policy']['set']['OWNER_SECRET'], 'synthetic-sentinel')

    def test_retirement_cannot_precede_native_session_projection(self):
        with self.assertRaises(Refused):
            ADAPTER.retire_reviewed_startup(self.config, ADAPTER.REVIEWED_BASH_ENV, 'linux')
        self.assertEqual(self.config.read_bytes(), self.initial)

    def test_both_apply_actions_require_current_reviewed_hash(self):
        for digest in [None, '0'*64]:
            with self.subTest(digest=digest), self.assertRaises(Refused):
                ADAPTER.project_native_session(self.config, 'linux', apply=True, reviewed_sha256=digest)
        old_hash = hashlib.sha256(self.initial).hexdigest()
        self.project()
        for digest in [None, old_hash, '0'*64]:
            with self.subTest(digest=digest), self.assertRaises(Refused):
                ADAPTER.retire_reviewed_startup(self.config, ADAPTER.REVIEWED_BASH_ENV, 'linux', apply=True, reviewed_sha256=digest)
        self.assertIn('BASH_ENV', tomllib.loads(self.config.read_text())['shell_environment_policy']['set'])

    def test_projection_preserves_identical_fields_and_refuses_conflicts(self):
        self.project()
        before = self.config.read_bytes()
        result = ADAPTER.project_native_session(self.config, 'linux')
        self.assertEqual(result['status'], 'unchanged')
        self.assertEqual(self.config.read_bytes(), before)
        for name in ['XDG_RUNTIME_DIR', 'DBUS_SESSION_BUS_ADDRESS']:
            binding = ADAPTER.verify_native_session(self.runtime, os.getuid())
            values = dict(binding); values[name] = 'owner-conflict'
            text = '[shell_environment_policy]\ninherit="core"\n[shell_environment_policy.set]\n'
            text += '\n'.join(json.dumps(k)+'='+json.dumps(v) for k,v in values.items())+'\n'
            with self.subTest(name=name), self.assertRaises(Refused):
                ADAPTER.render_native_session_projection(text, binding)

    def test_filters_refuse_session_projection_without_being_changed(self):
        for policy in ['exclude=["DBUS_*"]\n', 'include_only=["XDG_RUNTIME_DIR"]\n', '[shell_environment_policy.filters]\n"DBUS_*"="exclude"\n']:
            text = '[shell_environment_policy]\ninherit="core"\n'+policy
            with self.subTest(policy=policy), self.assertRaises(Refused):
                ADAPTER.render_native_session_projection(text, ADAPTER.verify_native_session(self.runtime, os.getuid()))

    def test_noncanonical_config_location_and_unknown_value_refuse(self):
        other = self.base/'project.toml'; other.write_bytes(self.initial)
        for operation in [lambda:ADAPTER.project_native_session(other,'linux'),
                          lambda:ADAPTER.retire_reviewed_startup(other,ADAPTER.REVIEWED_BASH_ENV,'linux'),
                          lambda:ADAPTER.retire_reviewed_startup(self.config,'/srv/unreviewed','linux'),
                          lambda:ADAPTER.project_native_session(self.config,'windows')]:
            with self.assertRaises(Refused): operation()
        self.assertEqual(self.config.read_bytes(), self.initial)

    def test_private_owned_directory_and_owned_nonlink_socket_are_required(self):
        self.runtime.chmod(0o755)
        with self.assertRaises(Refused): ADAPTER.verify_native_session(self.runtime,os.getuid())
        self.runtime.chmod(0o700)
        with self.assertRaises(Refused): ADAPTER.verify_native_session(self.runtime,os.getuid()+1)
        alias = self.base/'runtime-alias'; alias.symlink_to(self.runtime,target_is_directory=True)
        with self.assertRaises(Refused): ADAPTER.verify_native_session(alias,os.getuid())
        original_stat = Path.stat
        def changed_stat(path,*args,**kwargs):
            if path == self.bus:
                return types.SimpleNamespace(st_mode=stat.S_IFSOCK|0o777,st_uid=os.getuid()+1)
            return original_stat(path,*args,**kwargs)
        with patch.object(Path,'stat',new=changed_stat), self.assertRaises(Refused):
            ADAPTER.verify_native_session(self.runtime,os.getuid())

    def test_dead_bus_and_socket_link_are_rejected(self):
        self.listener.close()
        with self.assertRaises(Refused): ADAPTER.verify_native_session(self.runtime,os.getuid())
        self.bus.rename(self.runtime/'old-bus')
        self.bus.symlink_to('old-bus')
        with self.assertRaises(Refused): ADAPTER.verify_native_session(self.runtime,os.getuid())
