# ORE process-isolation funded proof carrier

Source repository: `ORESoftware/ores-proc-isolation-cli`
Candidate source PR: `#10`
Exact candidate PR head: `12e18d8653e6bb2a653a4606623b4addbf5f23be`
Exact source tree: `4b623fcc07f79ca24a36d4252e341decf3344115`

This carrier starts from the exact green #9 single-Bubblewrap snapshot and overlays
the exact three files changed by #10:

- `src/platform/mod.rs`: `767ec7e24722729cbbba3bb8f21d2528090668bd`
- `src/platform/linux.rs`: `9e0bff1e2c90353e8321fde4df9abe48aefb6b51`
- `tests/nixos_trusted_helper_contract.rs`: `1a1946145d8f7eb00e40536ba028ad388ca1412d`

The underlying single-boundary Linux helper and its namespace contract remain the
already-proven #9 blobs:

- Linux helper: `99faa05ef8f1184ee0d4931f589a2c510280305a`
- namespace contract: `3370ce2dc71646745f95ee74d4c2c0769d4b4dcc`

The candidate adds trusted NixOS system-profile helper discovery without consulting
inherited PATH. Helpers must canonicalize to root-owned executable regular files
that are not group/world writable; NixOS profile helpers must resolve beneath
immutable `/nix/store/`. Bash is resolved through the same trusted path.

This is proof-only and must never be merged into the test harness main branch.
