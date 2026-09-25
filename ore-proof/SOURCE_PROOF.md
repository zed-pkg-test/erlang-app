# ORE process-isolation funded proof carrier

Source repository: `ORESoftware/ores-proc-isolation-cli`
Candidate source PR: `#12`
Exact candidate PR head: `7361ddbb527eb34dba1b6fdc1266fe3466e55f73`
Exact source tree: `a129944af6c00b9d2ae35e7adfc3b389258a45fc`
Exact base main: `9261acc26e1285e75d005355b06bab4e478e6ae1`
Exact base tree: `4b623fcc07f79ca24a36d4252e341decf3344115`

This carrier starts from the already funded and merged #10 source snapshot, whose tree is
byte-identical to current main, and overlays only the three files changed by #12:

- `scripts/linux/ores-proc-isolate.sh`: `55840e9672969d7847e44a57bdb4c800c8454031`
- `tests/linux_helper_tripwire_contract.rs`: `c03c77ccf51e653472609de22e1e178ac30e2bba`
- `tests/nixos_trusted_helper_contract.rs`: `755e9eef0ec9d692dbcb9dc53abd38aed0f5a2b2`

The unchanged #10 trusted-helper authority remains pinned in the carrier:

- `src/platform/mod.rs`: `767ec7e24722729cbbba3bb8f21d2528090668bd`
- `src/platform/linux.rs`: `9e0bff1e2c90353e8321fde4df9abe48aefb6b51`

#12 keeps one Bubblewrap boundary without depending on Ubuntu-incompatible
`nsenter --user-parent`. For external networking Bubblewrap's first unprivileged user
namespace is paused before initialization; the host supervisor installs a one-ID uid/gid
map, enters only that descendant user namespace, sets its namespaced
`user.max_user_namespaces` to zero, and resumes Bubblewrap with
`--assert-userns-disabled`. The network namespace is therefore owned by the same
first-level user namespace that the trusted supervisor can enter using Ubuntu 24.04's
ordinary `nsenter -U --keep-caps`. The tenant still executes with `--cap-drop ALL`.

Required live proof is fail-closed: public Internet egress must work, while `/etc/passwd`,
host loopback, and the host's globally scoped interface must remain unreachable from the
sandbox. Any executed failure is a product/proof failure, not a runner-budget waiver.

This is proof-only and must never be merged into the test harness main branch.
