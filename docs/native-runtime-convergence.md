# Native runtime convergence acceptance

Status: 2026-11-25 continuation; incomplete. Installing Node 26.13.1 does not
change already accepted service artifacts or a project's locked dependency graph.
No service restart, policy overwrite or immutable artifact replacement is implied.

## Verified ordinary runtime and remaining shell adoption

The maintained installer provisions the native user nvm runtime and a separate
root-owned Node 26.13.1 distribution. The observed Node module ABI is 147. The
reviewed Codex shell action retains core inheritance and the verified native user
bus. Startup retirement now removes the exact reviewed assignment and records
`filters.BASH_ENV="exclude"` so inherited startup state is explicitly excluded.
A fresh chat turn still had the old startup value. Ordinary child adoption must
be verified after the supported saved-work/application reload boundary. Do not
unset variables for one command, weaken push admission, patch the vendor, or
assume a new turn reloaded configuration. The existing signed startup-unit commit
must publish through the normal project push command after admission succeeds.

## Project dependency compatibility

The RevealUI lockfile binds Vercel Python-analysis 0.11.0/0.11.1 to
`@renovatebot/pep440` 4.2.1. Its declared Node engines exclude 26. Authoritative npm
metadata checked on November 25 shows the 4.x line through 4.2.4 still excludes
26; 6.0.0 permits Node >=24.10.0. The root project's Vercel CLI is on the 52.x
line, while the current upstream latest is 66.6.0. Python-analysis latest is
0.15.3. These observations identify a compatibility route, not API equivalence.

A supported change must upgrade the owning dependency chain with a reviewed
lockfile, verify its actual consumers, install under Node 26 with engine-strict
unchanged, then run the maintained project gates. Do not force a transitive
major override or edit a dependency's engine declaration. Keep the existing
project Node24 pin until this succeeds. Registry metadata alone and host Node26
success are not project compatibility acceptance.

## Service artifact producer and custody

The installed daemon entry point is a maintained launcher into a digest-addressed
`runtime/bin/node` and `runtime/package/dist/cli.js`. The running accepted artifact
still binds Node24. Retain it until a replacement has been independently built,
reviewed, admitted and accepted through the existing lifecycle.

The observed RevDev producer is `packages/daemon/runtime-artifact.mjs`, with
`runtime-artifact.node-test.mjs`, in a retained validation checkout. It is not
present in the product's current `test` tree or its committed file history. Its
native build contract explicitly requires Node24.21.0 / ABI137 and pins native
headers, node-gyp inputs, approved builds and package/ELF inventory. Do not copy
that validation script into an installed runtime or change only its version
comparison to make Node26 pass. Preserve the owning uncommitted source closure.

First publish/review that producer and its complete dependency/native-build
contract in RevDev. Add a reviewed Node26.13.1 / ABI147 profile with matching
headers, toolchain and native addon evidence. Build a new ordinary-user candidate
from committed source. Use the maintained broker's daemon-custody artifact plan,
review its complete hashes and provenance, then follow the existing root custody
and operator launcher compare-and-swap lifecycle. Keep inverse receipts and the
previous artifact. Do not launch the replacement while active chats depend on
the existing daemon; actual restart and cold startup are coordinated acceptance.

The modern maintained broker source is on the retained native-fixture branch,
not current `test`. The installed accepted tool policy also binds a pre-upgrade
busctl digest. Tool rebinding and any broker source upgrade must use their
reviewed owner/CAS lifecycle before production admission can succeed. Direct
editing `/etc/revealfleet/agents/runtime.json`, replacing broker code in place,
or reusing a host-specific allow entry does not repair the source primitive.

## Existing one-offs and removal targets

Retained validation checkouts and their runtime producer are review inputs only;
remove reliance on them after the committed owning producer and accepted artifact
replace them. Old toolchains and digest artifacts remain while any consumer binds
them. Diagnostic fixture success, a running user bus and warm shell startup do
not prove the application cold-start deadline. Preserve the original service
units and source work until source publication and real consumer acceptance.
