# E2EE Compatibility

Overview of End-to-End Encryption protocol generations supported by Click.

## 1. Legacy Protocol v1 (Full Read & Write Compatibility)

Used for historical direct messages and legacy groups across Click web, Android, and iOS:

### Key Derivation
Direct messages:
```text
master = SHA-256("click-platforms-e2ee-v1-2024:" || sorted(userId1, userId2).joined(":") || ":" || connectionId)
encKey = SHA-256(master || 0x01)
macKey = SHA-256(master || 0x02)
```

Group messages:
```text
master = SHA-256("click-platforms-e2ee-v1-2024:group:" || groupId || ":" || groupSecret)
encKey = SHA-256(master || 0x01)
macKey = SHA-256(master || 0x02)
```

### Encryption & Packaging
- Cipher: AES-256-CBC with PKCS7 padding via `CommonCrypto`.
- MAC: HMAC-SHA256 computed over `IV || Ciphertext`.
- Direct wire format: `"e2e:" + Base64(IV[16] || HMAC[32] || Ciphertext)`
- Group wire format: `"e2e_grp:" + Base64(IV[16] || HMAC[32] || Ciphertext)`
- Notification Service Extension support: `NotificationService` decrypts `e2e:` previews using the legacy derivation formula when session context is present.

---

## 2. Current Protocol v2 (Active Multi-Device Protocol)

Upgraded direct, verified cliques, and event hubs:

### Device Identity & Keychain Vault
- **Key Type**: Curve25519 (X25519) keypair per device (`CryptoKit.Curve25519.KeyAgreement`).
- **Keychain Storage**: Secure enclave / Keychain item stored in `com.click.e2ee.v2` under key `x25519_identity_private_key`, protected with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **Public Key Encoding**: 44-byte ASN.1 DER SubjectPublicKeyInfo format:
  ```text
  30 2a 30 05 06 03 2b 65 6e 03 21 00 <32-byte-raw-public-key>
  ```
- **Device ID**: Hexadecimal representation of SHA-256 digest over the 44-byte DER SubjectPublicKeyInfo bytes.

### Epoch Key Agreement & Wrapping
- **Epoch Key**: Random cryptographically secure 256-bit symmetric key (`SymmetricKey(size: .bits256)`).
- **Recipient Wrapping**: For each active recipient device:
  1. Generate ephemeral X25519 keypair.
  2. Compute shared secret via Diffie-Hellman with recipient's public identity.
  3. Derive wrapping key via `HKDF<SHA256>.deriveKey` using info `ClickEpochKeyWrap-v2:<chatId>:<epoch>:<recipientDeviceId>`.
  4. Encrypt epoch key using AES-256-GCM.
  5. Package `WrappedEpochKey(recipientDeviceId, ephemeralPublicKeyDER, nonce, wrappedKey, tag)`.

### Message Envelope & Authenticated Additional Data (AAD)
- **Content Encryption**: AES-256-GCM using the 256-bit epoch key and unique 96-bit nonce.
- **Canonical AAD**: Canonical, deterministically sorted JSON dictionary without whitespace:
  ```json
  {"chatId":"...","clientMessageId":"...","cryptoVersion":2,"epoch":1,"senderDeviceId":"..."}
  ```
  Any tampering with message metadata causes GCM authentication failure and decryption rejection.
- **Wire Format**:
  ```text
  e2e:v2:{"c":"<base64_ciphertext_and_tag>","cid":"<client_message_id>","e":1,"n":"<base64_nonce>","sd":"<sender_device_id>"}
  ```

### Replay & Ordering Guard
- **Replay Protection**: `ReplayGuard` maintains an in-memory and persisted set of recently received message nonces and client message IDs per chat channel.
- **Monotonicity**: Disallows regression of epoch keys without verified re-keying handshake.

---

## 3. Verification & Test Vectors

Automated unit tests in [`Tests/ClickTests/ClickCryptoTests.swift`](file:///Users/timberlake2025/Code/Click%20Platforms/click-ios/Tests/ClickTests/ClickCryptoTests.swift) verify:
- Deterministic V1 key derivation matching TypeScript and backend implementations.
- V1 direct message encrypt/decrypt roundtrip and tampering detection.
- V1 group message encrypt/decrypt roundtrip with `e2e_grp:` prefix.
- V2 SPKI 44-byte ASN.1 DER export, import, and device ID computation.
- V2 AES-256-GCM encryption with canonical AAD metadata.
- Rejection of tampered ciphertext, tampered nonce, or tampered metadata.
- V2 ReplayGuard duplicate detection.
- V2 Epoch key multi-device wrap and unwrap across independent device keypairs.
