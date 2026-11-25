"""TEST ONLY: process boundary for a precreated NEW ordinary synthetic fixture.
Never installed/launched by the production worker or controller.
"""
import importlib.util
import json
import os
from pathlib import Path
import sys


def main(arguments):
    if os.geteuid() == 0 or len(arguments) != 2 or arguments[0] != '--synthetic-context':
        return 3
    context=Path(arguments[1])
    if context.name != 'synthetic-worker-context.json' or context.resolve() != context:
        return 3
    info=context.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        return 3
    value=json.loads(context.read_text())
    if set(value) != {'testKind','binary','repository','state','binding'} or value['testKind'] != 'new-private-borg-protocol-test-v1':
        return 3
    root=context.parent
    if any(Path(value[key]).parent != root for key in ('repository','state')):
        return 3
    spec=importlib.util.spec_from_file_location('cold', Path(__file__).resolve().parents[2]/'scripts/lib/wsl_cold_container.py')
    cold=importlib.util.module_from_spec(spec); spec.loader.exec_module(cold)
    session=cold.Session(Path(value['binary']),Path(value['repository']),Path(value['state']),value['binding'],timeout=30,idle=5)
    try:
        session.serve(0,1)
        return 0
    except cold.Refused:
        return 3


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
