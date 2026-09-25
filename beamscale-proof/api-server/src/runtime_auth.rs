use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{env, time::{SystemTime, UNIX_EPOCH}};
use uuid::Uuid;

pub const CONTRACT_VERSION: &str = "bmscl.runtime-control.v1";
const DEFAULT_TTL_SECONDS: u64 = 30;
const MAX_TTL_SECONDS: u64 = 60;

#[derive(Debug, Clone, Serialize)]
pub struct SignedRequest<'a, T: Serialize + ?Sized> {
    pub contract: RuntimeContract,
    pub request: &'a T,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct RuntimeContract {
    pub version: String,
    pub operation: String,
    pub tenant_id: String,
    pub shard_id: String,
    pub execution_class: String,
    pub execution_backend: String,
    pub runtime_epoch: u64,
    pub request_sha256: String,
    pub issued_at_unix: u64,
    pub expires_at_unix: u64,
    pub nonce: String,
    pub signature: String,
}

pub fn load_secret() -> Result<Vec<u8>, String> {
    let value = env::var("BMSCL_RUNTIME_CONTROL_SECRET")
        .map_err(|_| "BMSCL_RUNTIME_CONTROL_SECRET is required".to_string())?;
    let bytes = value.into_bytes();
    if bytes.len() < 32 {
        return Err("BMSCL_RUNTIME_CONTROL_SECRET must be at least 32 bytes".into());
    }
    Ok(bytes)
}

pub fn sign_request<'a, T: Serialize + ?Sized>(
    secret: &[u8],
    operation: &str,
    tenant_id: &str,
    shard_id: &str,
    execution_class: &str,
    execution_backend: &str,
    runtime_epoch: u64,
    request: &'a T,
) -> Result<SignedRequest<'a, T>, String> {
    if secret.len() < 32 {
        return Err("runtime control secret is invalid".into());
    }
    let issued_at_unix = now_unix()?;
    let ttl = env::var("BMSCL_RUNTIME_CONTROL_TTL_SECONDS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(DEFAULT_TTL_SECONDS);
    if ttl == 0 || ttl > MAX_TTL_SECONDS {
        return Err(format!(
            "BMSCL_RUNTIME_CONTROL_TTL_SECONDS must be 1..={MAX_TTL_SECONDS}"
        ));
    }
    let request_sha256 = request_sha256(request)?;
    let mut contract = RuntimeContract {
        version: CONTRACT_VERSION.into(),
        operation: operation.into(),
        tenant_id: tenant_id.into(),
        shard_id: shard_id.into(),
        execution_class: execution_class.into(),
        execution_backend: execution_backend.into(),
        runtime_epoch,
        request_sha256: request_sha256.clone(),
        issued_at_unix,
        expires_at_unix: issued_at_unix + ttl,
        nonce: Uuid::new_v4().simple().to_string(),
        signature: String::new(),
    };
    contract.signature = signature_for(secret, &contract, &request_sha256);
    Ok(SignedRequest { contract, request })
}

fn request_sha256<T: Serialize + ?Sized>(request: &T) -> Result<String, String> {
    let bytes = serde_json::to_vec(request)
        .map_err(|err| format!("serialize runtime control request: {err}"))?;
    Ok(hex_lower(&Sha256::digest(bytes)))
}

fn signature_for(
    secret: &[u8],
    contract: &RuntimeContract,
    request_sha256: &str,
) -> String {
    let canonical = format!(
        "{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n",
        contract.version,
        contract.operation,
        contract.tenant_id,
        contract.shard_id,
        contract.execution_class,
        contract.execution_backend,
        contract.runtime_epoch,
        request_sha256,
        contract.issued_at_unix,
        contract.expires_at_unix,
        contract.nonce
    );
    hex_lower(&hmac_sha256(secret, canonical.as_bytes()))
}

fn now_unix() -> Result<u64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|_| "system clock is before UNIX epoch".into())
}

fn hmac_sha256(secret: &[u8], message: &[u8]) -> [u8; 32] {
    const BLOCK: usize = 64;
    let mut key = [0u8; BLOCK];
    if secret.len() > BLOCK {
        let digest = Sha256::digest(secret);
        key[..32].copy_from_slice(&digest);
    } else {
        key[..secret.len()].copy_from_slice(secret);
    }
    let mut ipad = [0x36u8; BLOCK];
    let mut opad = [0x5cu8; BLOCK];
    for index in 0..BLOCK {
        ipad[index] ^= key[index];
        opad[index] ^= key[index];
    }
    let mut inner = Sha256::new();
    inner.update(ipad);
    inner.update(message);
    let inner_digest = inner.finalize();

    let mut outer = Sha256::new();
    outer.update(opad);
    outer.update(inner_digest);
    outer.finalize().into()
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write;
        let _ = write!(out, "{byte:02x}");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Serialize)]
    struct Request {
        value: u64,
    }

    #[test]
    fn signing_is_deterministically_bound_to_request_digest() {
        let secret = b"0123456789abcdef0123456789abcdef";
        let request = Request { value: 42 };
        let signed = sign_request(
            secret,
            "invoke",
            "tenant-a",
            "0",
            "phoenix",
            "firecracker",
            7,
            &request,
        )
        .unwrap();
        assert_eq!(signed.contract.version, CONTRACT_VERSION);
        assert_eq!(signed.contract.operation, "invoke");
        assert_eq!(signed.contract.tenant_id, "tenant-a");
        assert_eq!(signed.contract.signature.len(), 64);
        assert_eq!(signed.contract.request_sha256.len(), 64);
    }
}
