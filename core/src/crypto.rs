//! Per-tenant sealing of provider credentials: AES-256-GCM with a key derived
//! from the server master key (HKDF-SHA256, tenant id as context). The blob is
//! bound to its tenant and provider as associated data, so a copied row will
//! not decrypt anywhere else.
use aes_gcm::{
    Aes256Gcm, Key, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use hkdf::Hkdf;
use sha2::Sha256;

fn cipher(master: &[u8; 32], tenant: &str) -> Aes256Gcm {
    let mut k = [0u8; 32];
    Hkdf::<Sha256>::new(Some(b"rupert-v1"), master)
        .expand(format!("tenant:{tenant}").as_bytes(), &mut k)
        .expect("32 bytes");
    Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&k))
}

pub fn seal(master: &[u8; 32], tenant: &str, provider: &str, plain: &[u8]) -> Vec<u8> {
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut nonce).expect("os randomness");
    let aad = format!("{tenant}:{provider}");
    let ct = cipher(master, tenant)
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plain,
                aad: aad.as_bytes(),
            },
        )
        .expect("encrypt");
    [nonce.to_vec(), ct].concat()
}

pub fn open(master: &[u8; 32], tenant: &str, provider: &str, blob: &[u8]) -> Option<Vec<u8>> {
    if blob.len() < 12 + 16 {
        return None;
    }
    let aad = format!("{tenant}:{provider}");
    cipher(master, tenant)
        .decrypt(
            Nonce::from_slice(&blob[..12]),
            Payload {
                msg: &blob[12..],
                aad: aad.as_bytes(),
            },
        )
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn roundtrip_and_binding() {
        let m = [7u8; 32];
        let blob = seal(&m, "t1", "shopify", b"secret");
        assert_eq!(
            open(&m, "t1", "shopify", &blob).as_deref(),
            Some(&b"secret"[..])
        );
        assert!(open(&m, "t2", "shopify", &blob).is_none(), "other tenant");
        assert!(open(&m, "t1", "square", &blob).is_none(), "other provider");
        assert!(
            open(&[8u8; 32], "t1", "shopify", &blob).is_none(),
            "other master key"
        );
    }
}
