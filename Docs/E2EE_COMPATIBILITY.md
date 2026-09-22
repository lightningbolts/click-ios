# E2EE Compatibility

Overview of End-to-End Encryption protocol generations supported by Click.

## 1. Legacy Protocol v1 (Read Compatibility)

Used for historical direct messages and legacy groups:
```text
master = SHA-256("click-platforms-e2ee-v1-2024" || sorted(userId1, userId2) || connectionId)
encKey = SHA-256(master || 0x01)
macKey = SHA-256(master || 0x02)

payload = IV[16] || HMAC[32] || AES-CBC ciphertext
wire format = "e2e:" + Base64(payload)
```

## 2. Current Protocol v2 (Active Protocol)

Upgraded direct, verified cliques, and event hubs:
- **Device Identity**: X25519 keypair per device. Private key stored in iOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **Epoch Keys**: Random 256-bit symmetric epoch key.
- **Key Wrapping**: Ephemeral X25519 + HKDF-SHA256 + AES-256-GCM to each participant device.
- **Envelope Authentication**: Chat/Hub ID, client message ID, sender device ID, epoch number, crypto version, nonce, ciphertext digest.
- **Replay Protection**: Nonce checking and monotonic epoch ordering.
