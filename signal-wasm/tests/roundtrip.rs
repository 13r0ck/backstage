//! `encrypt` against a recipient generated with libsignal, decrypted back
//! with libsignal: the ciphertext, plaintext encoding and padding are right.

use std::future::Future;
use std::pin::pin;
use std::task::{Context, Poll, Waker};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use libsignal_protocol::*;
use rand::TryRngCore as _;
use rand::rngs::OsRng;

const BOT: &str = "9d0652a3-dcc3-4d11-975f-74d61598733f";
const TARGET: &str = "6fb6f1a5-3c1e-4b7c-8f4e-5d2a1b0c9e8d";

fn run<T>(f: impl Future<Output = T>) -> T {
    match pin!(f).poll(&mut Context::from_waker(Waker::noop())) {
        Poll::Ready(t) => t,
        Poll::Pending => panic!("pending"),
    }
}

/// A recipient device's store, plus its bundle as `GET /v2/keys` returns it.
fn recipient(device_id: u32, with_pre_key: bool) -> (InMemSignalProtocolStore, serde_json::Value) {
    let mut rng = OsRng.unwrap_err();
    let identity = IdentityKeyPair::generate(&mut rng);
    let mut store = InMemSignalProtocolStore::new(identity, 4321).unwrap();
    let b64 = |b: &[u8]| STANDARD.encode(b);

    let pre_key = KeyPair::generate(&mut rng);
    let signed = KeyPair::generate(&mut rng);
    let signed_sig = identity.private_key().calculate_signature(&signed.public_key.serialize(), &mut rng).unwrap();
    let kyber = KyberPreKeyRecord::generate(kem::KeyType::Kyber1024, 3.into(), identity.private_key()).unwrap();
    run(async {
        store.save_pre_key(1.into(), &PreKeyRecord::new(1.into(), &pre_key)).await.unwrap();
        store
            .save_signed_pre_key(2.into(), &SignedPreKeyRecord::new(2.into(), Timestamp::from_epoch_millis(1), &signed, &signed_sig))
            .await
            .unwrap();
        store.save_kyber_pre_key(3.into(), &kyber).await.unwrap();
    });

    let mut device = serde_json::json!({
        "deviceId": device_id,
        "registrationId": 4321,
        "signedPreKey": { "keyId": 2, "publicKey": b64(&signed.public_key.serialize()), "signature": b64(&signed_sig) },
        "pqPreKey": {
            "keyId": 3,
            "publicKey": b64(&kyber.public_key().unwrap().serialize()),
            "signature": b64(&kyber.signature().unwrap()),
        },
    });
    if with_pre_key {
        device["preKey"] = serde_json::json!({ "keyId": 1, "publicKey": b64(&pre_key.public_key.serialize()) });
    }
    let keys = serde_json::json!({
        "identityKey": b64(&identity.identity_key().serialize()).trim_end_matches('='),
        "devices": [device],
    });
    (store, keys)
}

fn roundtrip(text: &str, with_pre_key: bool) {
    let mut rng = OsRng.unwrap_err();
    let bot = IdentityKeyPair::generate(&mut rng);
    let (mut store, keys) = recipient(2, with_pre_key);
    let timestamp = 1_700_000_000_123u64;

    let out = signal_wasm::encrypt(
        &STANDARD.encode(bot.private_key().serialize()),
        1234,
        BOT,
        TARGET,
        2,
        &keys.to_string(),
        text,
        timestamp as f64,
    )
    .unwrap();
    let out: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert_eq!(out["type"], 3);
    assert_eq!(out["destinationDeviceId"], 2);
    assert_eq!(out["destinationRegistrationId"], 4321);

    let bytes = STANDARD.decode(out["content"].as_str().unwrap()).unwrap();
    let message = PreKeySignalMessage::try_from(bytes.as_slice()).unwrap();
    assert_eq!(message.registration_id(), 1234);
    let plaintext = run(message_decrypt(
        &CiphertextMessage::PreKeySignalMessage(message),
        &ProtocolAddress::new(BOT.into(), DeviceId::new(1).unwrap()),
        &ProtocolAddress::new(TARGET.into(), DeviceId::new(2).unwrap()),
        &mut store.session_store,
        &mut store.identity_store,
        &mut store.pre_key_store,
        &store.signed_pre_key_store,
        &mut store.kyber_pre_key_store,
        &mut rng,
    ))
    .unwrap();

    let content = signal_wasm::content(text, timestamp);
    assert_eq!(plaintext.len() % 160, 159);
    assert_eq!(&plaintext[..content.len()], content.as_slice());
    assert_eq!(plaintext[content.len()], 0x80);
    assert!(plaintext[content.len() + 1..].iter().all(|&b| b == 0));
}

#[test]
fn decrypts_with_one_time_pre_key() {
    roundtrip("hello world", true);
}

#[test]
fn decrypts_without_one_time_pre_key() {
    roundtrip(&"long ".repeat(100), false);
}

#[test]
fn content_encoding() {
    // Content{dataMessage{body:"hi", timestamp:300}}
    assert_eq!(signal_wasm::content("hi", 300), [0x0a, 0x07, 0x0a, 0x02, b'h', b'i', 0x38, 0xac, 0x02]);
}

#[test]
fn rejects_unknown_device() {
    let (_, keys) = recipient(1, true);
    let key = STANDARD.encode(IdentityKeyPair::generate(&mut OsRng.unwrap_err()).private_key().serialize());
    let e = signal_wasm::encrypt(&key, 1, BOT, TARGET, 5, &keys.to_string(), "x", 1.0).unwrap_err();
    assert!(e.contains("device 5"), "{e}");
}

/// Prints a recipient bundle for the site's /send-test route:
/// `cargo test --release -- --ignored --nocapture print_fixture`
#[test]
#[ignore]
fn print_fixture() {
    let (_, keys) = recipient(1, true);
    println!("{keys}");
}
