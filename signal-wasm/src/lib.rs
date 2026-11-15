//! A thin, stateless wasm wrapper over libsignal for sending one message.
//!
//! `encrypt` starts a fresh session from a recipient device's pre-key bundle
//! and encrypts a text message for it. All cryptography (key validation,
//! signature checks, PQXDH, the ratchet) is libsignal's; this file only
//! parses JSON and base64 and hand-encodes the tiny plaintext protobuf.
//!
//! Never call `SystemTime::now()` here: it panics on wasm32-unknown-unknown.
//! Time comes in as the `timestamp` argument.

use std::future::Future;
use std::pin::pin;
use std::task::{Context, Poll, Waker};
use std::time::{Duration, UNIX_EPOCH};

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD};
use libsignal_protocol::{
    CiphertextMessageType, DeviceId, IdentityKey, IdentityKeyPair, InMemSignalProtocolStore,
    PreKeyBundle, PrivateKey, ProtocolAddress, PublicKey, kem, message_encrypt,
    process_prekey_bundle,
};
use rand::TryRngCore as _;
use serde::Deserialize;
use wasm_bindgen::prelude::*;

/// Encrypts `text` for one device of `target_aci`, as a new session.
///
/// - `identity_private_key`: base64 of the bot's 32-byte identity private key.
/// - `keys_json`: the body of `GET /v2/keys/{target_aci}/*`.
/// - `device_id`: which device of `keys_json` to encrypt for.
/// - `timestamp`: milliseconds since the epoch; also the message timestamp.
///
/// Returns one entry of `PUT /v1/messages`' `messages` array, as JSON:
/// `{type, destinationDeviceId, destinationRegistrationId, content}`.
#[wasm_bindgen]
#[allow(clippy::too_many_arguments)]
pub fn encrypt(
    identity_private_key: &str,
    registration_id: u32,
    bot_aci: &str,
    target_aci: &str,
    device_id: u32,
    keys_json: &str,
    text: &str,
    timestamp: f64,
) -> Result<String, String> {
    let timestamp = timestamp as u64;
    let private = PrivateKey::deserialize(&b64(identity_private_key)?).map_err(err)?;
    let identity = IdentityKeyPair::new(IdentityKey::new(private.public_key().map_err(err)?), private);

    let keys: Keys = serde_json::from_str(keys_json).map_err(err)?;
    let device = keys
        .devices
        .iter()
        .find(|d| d.device_id == device_id)
        .ok_or_else(|| format!("no bundle for device {device_id}"))?;
    let device_id = DeviceId::new(u8::try_from(device_id).map_err(err)?).map_err(err)?;
    let pre_key = match &device.pre_key {
        Some(k) => Some((k.key_id.into(), PublicKey::deserialize(&b64(&k.public_key)?).map_err(err)?)),
        None => None,
    };
    let signed = &device.signed_pre_key;
    let pq = &device.pq_pre_key;
    let bundle = PreKeyBundle::new(
        device.registration_id,
        device_id,
        pre_key,
        signed.key_id.into(),
        PublicKey::deserialize(&b64(&signed.public_key)?).map_err(err)?,
        b64(signed.signature.as_deref().unwrap_or_default())?,
        pq.key_id.into(),
        kem::PublicKey::deserialize(&b64(&pq.public_key)?).map_err(err)?,
        b64(pq.signature.as_deref().unwrap_or_default())?,
        IdentityKey::decode(&b64(&keys.identity_key)?).map_err(err)?,
    )
    .map_err(err)?;

    let remote = ProtocolAddress::new(target_aci.to_owned(), device_id);
    let local = ProtocolAddress::new(bot_aci.to_owned(), DeviceId::new(1).map_err(err)?);
    let mut store = InMemSignalProtocolStore::new(identity, registration_id).map_err(err)?;
    let now = UNIX_EPOCH + Duration::from_millis(timestamp);
    let mut rng = rand::rngs::OsRng.unwrap_err();

    let message = run(async {
        process_prekey_bundle(
            &remote,
            &local,
            &mut store.session_store,
            &mut store.identity_store,
            &bundle,
            now,
            &mut rng,
        )
        .await?;
        message_encrypt(
            &padded(&content(text, timestamp)),
            &remote,
            &local,
            &mut store.session_store,
            &mut store.identity_store,
            now,
            &mut rng,
        )
        .await
    })
    .map_err(err)?;

    let kind = match message.message_type() {
        CiphertextMessageType::PreKey => 3,
        CiphertextMessageType::Whisper => 1,
        other => return Err(format!("unexpected message type {other:?}")),
    };
    Ok(serde_json::json!({
        "type": kind,
        "destinationDeviceId": u32::from(device_id),
        "destinationRegistrationId": device.registration_id,
        "content": STANDARD.encode(message.serialize()),
    })
    .to_string())
}

/// `GET /v2/keys/{id}/*`, the fields we use.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Keys {
    identity_key: String,
    devices: Vec<Device>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Device {
    device_id: u32,
    registration_id: u32,
    pre_key: Option<Key>,
    signed_pre_key: Key,
    pq_pre_key: Key,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Key {
    key_id: u32,
    public_key: String,
    signature: Option<String>,
}

/// The server's base64 is standard, with or without padding.
fn b64(s: &str) -> Result<Vec<u8>, String> {
    STANDARD_NO_PAD.decode(s.trim_end_matches('=')).map_err(err)
}

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// libsignal's API is async, but with in-memory stores nothing ever waits.
fn run<T>(f: impl Future<Output = T>) -> T {
    match pin!(f).poll(&mut Context::from_waker(Waker::noop())) {
        Poll::Ready(t) => t,
        Poll::Pending => unreachable!("in-memory stores never block"),
    }
}

/// `Content { dataMessage = 1: DataMessage { body = 1, timestamp = 7 } }`.
pub fn content(text: &str, timestamp: u64) -> Vec<u8> {
    let mut data = Vec::new();
    field(&mut data, 1, text.as_bytes());
    data.push(7 << 3); // field 7, varint
    varint(&mut data, timestamp);
    let mut out = Vec::new();
    field(&mut out, 1, &data);
    out
}

/// A length-delimited protobuf field.
fn field(out: &mut Vec<u8>, number: u8, bytes: &[u8]) {
    out.push(number << 3 | 2);
    varint(out, bytes.len() as u64);
    out.extend_from_slice(bytes);
}

fn varint(out: &mut Vec<u8>, mut n: u64) {
    while n >= 0x80 {
        out.push(n as u8 | 0x80);
        n >>= 7;
    }
    out.push(n as u8);
}

/// Signal's transport padding, as its clients do it: the message, 0x80, then
/// zeros, up to one byte short of a multiple of 160.
pub fn padded(message: &[u8]) -> Vec<u8> {
    let len = (message.len() + 2).div_ceil(160) * 160 - 1;
    let mut out = message.to_vec();
    out.push(0x80);
    out.resize(len, 0);
    out
}
