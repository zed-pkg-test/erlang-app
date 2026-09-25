#!/usr/bin/env python3
import json
import pathlib
import sys

if len(sys.argv) != 5:
    raise SystemExit("usage: verify_phoenix_runtime_preflight.py LOCK INFRA API SUPERVISOR")

lock_path, infra_root, api_root, supervisor_root = map(pathlib.Path, sys.argv[1:])
lock = json.loads(lock_path.read_text())
assert lock["schema_version"] == "beamscale.phoenix-e2e-source-lock.v2"

contract = json.loads(
    (infra_root / "deploy/firecracker/runtime-host-contract.json").read_text()
)
assert contract["schemaVersion"] == "beamscale.firecracker-runtime.v1"
assert set(contract["acceptedExecutionClasses"]) == {"phoenix", "durable_actor"}
assert contract["requiredBackend"] == "firecracker"
assert contract["tenantIsolation"] == "single_tenant_microvm"
auth = contract["controlAuthentication"]
assert auth["contractVersion"] == "bmscl.runtime-control.v1"
assert auth["scheme"] == "hmac-sha256"
assert auth["nonceReplay"] == "reject_once_consumed"

api_control = (api_root / "src/runtime_control.rs").read_text()
runtime_auth = (
    infra_root / "modules/tenant_runtime/runtime-host/src/runtime_auth.rs"
).read_text()

for source in (api_control, runtime_auth):
    assert 'bmscl.runtime-control.v1' in source
    assert 'dc60e632a90329ccfd34fbe904d94704dbbb6669575185e26389854ff64139c3' in source
    assert 'e55da196d53024c61f189b3aaaec564bf564c6394e991024a50e03543c08e7dd' in source

supervisor_policy = (supervisor_root / "src/bmscl_execution_policy.erl").read_text()
supervisor_profile = (supervisor_root / "src/bmscl_faas_profile.erl").read_text()
assert "single_tenant_microvm" in supervisor_policy
assert "phoenix_v1" in supervisor_policy
assert "firecracker" in supervisor_profile

print("PASS: Phoenix control-plane/runtime Firecracker contracts agree")
