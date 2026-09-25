# ORE process-isolation funded proof carrier

Source repository: `ORESoftware/ores-proc-isolation-cli`
Candidate source PR: `#9`
Exact candidate PR head: `d4dad9eec6900bf1873ce42650d9b24395e879ec`
Exact source tree: `6cb09d8ce9773b3389fd8af3dd57576f08b9cfb1`

All source/config/test/vendor Git blobs in this carrier are the exact source
blob IDs from that candidate head. Relative to merged #7, the Linux helper and
its namespace contract test are the changed security boundary:
`99faa05ef8f1184ee0d4931f589a2c510280305a` and `3370ce2dc71646745f95ee74d4c2c0769d4b4dcc`.

The candidate uses one Bubblewrap setup transaction for the tenant user, IPC,
PID, network, UTS and cgroup namespaces. The tenant is mapped to uid/gid 0 only
inside its unprivileged user namespace so namespace setup can finish, then
`--disable-userns` and `--cap-drop ALL` are applied before target exec.

For external networking, host-supervised slirp4netns is bound to the exact
`/proc/<child>/ns/user` and `/proc/<child>/ns/net` paths; firewall setup
enters the child user namespace before the network namespace. No nested
Bubblewrap or host-root capability is introduced.

This is proof-only and must never be merged into the honeypot daemon.
