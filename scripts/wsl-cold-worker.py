#!/usr/bin/python3
"""Fixed signed-policy worker. Does not provision, mount, initialize or schedule."""
import importlib.util
import configparser
import hashlib
import json
import os
from pathlib import Path
import sys
import time


def load_module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def main(arguments):
    control=bool(arguments) and arguments[0] in ('--control-prepare','--control-status','--control-reconcile','--control-probe')
    if control: arguments=['--'+arguments[0][len('--control-'):],*arguments[1:]]
    reconciling=len(arguments)==2 and arguments[0] in ('--reconcile','--status')
    if not reconciling and arguments not in (['--readiness'],['--prepare'],['--serve'],['--probe']): return 3
    # Bootstrap trusted ownership BEFORE importing deployment code. No root
    # process may load Python from this user-writable development checkout.
    if os.geteuid()!=0 or not sys.flags.isolated or not sys.dont_write_bytecode:
        print(json.dumps({'canExecute':False,'gate':'root-immutable-deployment-required'})) if arguments==['--readiness'] else None
        return 3
    root=Path(__file__).resolve().parent
    for path in (Path(__file__),root,root/'lib',root/'lib/wsl_cold_admission.py',*root.parents):
        info=path.lstat()
        if path.resolve()!=path or info.st_uid!=0 or info.st_mode & 0o022:
            return 3
    if control:
        sys.stdout.buffer.write(b'revkit-cold-control-started-v1\n');sys.stdout.buffer.flush()
    if arguments==['--probe']:
        # Fixed read-only cold-control diagnostic, not policy/runtime admission.
        try:
            config=configparser.ConfigParser(interpolation=None)
            config.read('/etc/wsl.conf')
            print(json.dumps({'profile':'cold-worker-control-probe-v1','runtimeAdmitted':False,
                              'sourceRelease':root.parent.name,'bootInitMilliseconds':config.getint('boot','initTimeout',fallback=10000),
                              'kernelBootId':Path('/proc/sys/kernel/random/boot_id').read_text().strip()}))
            return 0
        except BaseException:
            print('Cold worker control probe refused',file=sys.stderr);return 3
    admission=load_module('cold_admission',root/'lib/wsl_cold_admission.py')
    try:
        policy,binding,observed=admission.load(allow_expired=reconciling)
        if reconciling:
            print(json.dumps((admission.status if arguments[0]=='--status' else admission.reconcile)(policy,binding,arguments[1])))
            return 0
        if arguments!=['--serve']:
            print(json.dumps({'profile':policy['profile'],'bindingSha256':binding,'runtimeAdmitted':True,
                              'backendExecuted':False,'repositoryId':policy['repository']['id'],'repositoryInitialized':observed is not None,
                              'repositoryObservationSha256':hashlib.sha256(json.dumps(observed,separators=(',',':')).encode()).hexdigest() if observed is not None else None,
                              'fullBackupAccepted':False,'fullRestoreAccepted':False}))
            return 0
        if policy['operation']=='prepare': return 3
        engine=load_module('cold_engine',root/'lib/wsl_cold_container.py')
        deployment=admission.Deployment(policy,binding,observed)
        session=engine.Session(policy['worker']['borg'],policy['repository']['path'],policy['worker']['state'],binding,
                               timeout=policy['budget']['timeoutSeconds'],deployment=deployment)
        try:
            session.serve(0,1)
            return 0
        except BaseException:
            if not session.group_gone:
                # Keep locks; supervised unit stop/RuntimeMaxSec is the final owner.
                # Never claim Linux exit or release caller custody on this path.
                while True: time.sleep(1)
            return 3
    except BaseException as exc:
        # Fixed nonsecret gate codes only; no paths/keys/child diagnostics.
        code=str(exc) if isinstance(exc,admission.AdmissionError) else type(exc).__name__
        print('Cold worker admission refused: '+code,file=sys.stderr)
        return 3


if __name__=='__main__': sys.exit(main(sys.argv[1:]))
