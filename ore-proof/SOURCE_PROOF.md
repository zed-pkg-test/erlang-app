# ORE process-isolation funded proof carrier

Source repository: `ORESoftware/ores-proc-isolation-cli`
Candidate source PR: `#12`
Exact candidate PR head: `9024b512c905f980b7117962f340ad7e556e52f9`
Exact source tree: `bf56aa7d6971e25d109ce977e0aaec01222ceedb`
Exact base main: `9261acc26e1285e75d005355b06bab4e478e6ae1`
Exact base tree: `4b623fcc07f79ca24a36d4252e341decf3344115`

This carrier starts from the already funded and merged #10 source snapshot, whose tree is
byte-identical to current main, and overlays only the three files changed by #12:

- `scripts/linux/ores-proc-isolate.sh`: `d9195d1406247940bbd456ee67af3c55dbfc600d`
- `tests/linux_helper_tripwire_contract.rs`: `af068e03f451235c686db341b7a15ff922778f55`
- `tests/nixos_trusted_helper_contract.rs`: `5f0fec46e5c228d81594cd67a442342d025c6bbe`

The unchanged #10 trusted-helper authority remains pinned in the carrier:

- `src/platform/mod.rs`: `767ec7e24722729cbbba3bb8f21d2528090668bd`
- `src/platform/linux.rs`: `9e0bff1e2c90353e8321fde4df9abe48aefb6b51`

#12 changes only the external-network namespace handoff and its contracts. The trusted
host-side network supervisor enters Bubblewrap's **parent user namespace** before the
network namespace, so `slirp4netns`, `ip`, and firewall helpers receive capabilities only
inside that descendant user namespace. The tenant itself remains in the nested
`--disable-userns` namespace and still executes with `--cap-drop ALL`.

Required live proof is fail-closed: public Internet egress must work, while `/etc/passwd`,
host loopback, and the host's globally scoped interface must remain unreachable from the
sandbox. Any executed failure is a product/proof failure, not a runner-budget waiver.

This is proof-only and must never be merged into the test harness main branch.
