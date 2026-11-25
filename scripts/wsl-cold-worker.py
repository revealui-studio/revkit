#!/usr/bin/python3
"""Fixed worker admission boundary. No arbitrary commands, paths or test flags.

The engine is implemented in lib/wsl_cold_container.py. Runtime admission is
closed until Windows/selected-worker integration and immutable deployment policy
are reviewed. This executable deliberately cannot be activated by wire input.
"""
import json
import sys

GATES = (
    'immutable-worker-interpreter-source-and-signed-borg-deployment',
    'authoritative-windows-registration-final-handle-and-continuous-source-lease',
    'actual-windows-to-selected-worker-framed-lifetime-acceptance',
    'independent-repository-identity-exclusive-access-and-native-lock-plan',
    'fresh-per-filesystem-capacity-overhead-reserve-and-source-outage',
    'independent-production-key-recovery-and-controller-admission-receipt',
)


def main(arguments):
    if arguments != ['--readiness']:
        # No stdin/secret, repository, tool, state, source or worker probe happens.
        print('Cold worker production admission is closed; no backend opened.', file=sys.stderr)
        return 3
    print(json.dumps({'protocol': 'revkit-cold-worker-v1', 'profile': 'cold-vhd-container-v1',
                      'canExecute': False, 'backendExecuted': False, 'gates': GATES}))
    return 3


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
