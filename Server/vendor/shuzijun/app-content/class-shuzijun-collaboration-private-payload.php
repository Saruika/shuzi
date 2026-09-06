<?php

/**
 * Authenticated envelope for collaboration storage. Not a mail transport
 * and not a feature switch. The caller must authorize before decrypting and
 * must supply a dedicated collaboration key, never an Apple signing/data key.
 */
final class Shuzijun_Collaboration_Private_Payload {
    private $key;
    private $key_id;
    private const MAX_BYTES = 32768;
    private const FIELDS = array(
        'contactName', 'contactMethod', 'organization', 'projectType',
        'city', 'preferredDate', 'budget', 'details',
    );

    public function __construct(#[\SensitiveParameter] $key, $key_id) {
        if (!function_exists('sodium_crypto_aead_xchacha20poly1305_ietf_encrypt')
            || !function_exists('sodium_crypto_aead_xchacha20poly1305_ietf_decrypt')
            || !function_exists('sodium_memzero') || !is_string($key) || strlen($key) !== 32
            || !is_string($key_id) || preg_match('/^[a-z0-9][a-z0-9_-]{0,31}$/D', $key_id) !== 1) {
            throw new InvalidArgumentException('collaboration_cipher_unavailable');
        }
        $this->key = $key;
        $this->key_id = $key_id;
    }

    public function __destruct() {
        if (is_string($this->key) && $this->key !== '') { sodium_memzero($this->key); }
    }

    public function __debugInfo() { return array('keyID' => $this->key_id, 'key' => '[redacted]'); }
    public function __serialize(): array { throw new LogicException('collaboration_cipher_not_serializable'); }
    public function __unserialize(array $data): void { throw new LogicException('collaboration_cipher_not_serializable'); }
    private function __clone() {}

    /** Dedicated, deployment-owned key outside the WordPress document root. */
    public static function from_file($configured_path, $key_id, $document_root) {
        $key = null;
        $handle = false;
        try {
            if (!is_string($configured_path) || !is_string($document_root)
                || $configured_path === '' || $configured_path[0] !== '/') { return null; }
            $root = realpath($document_root);
            $path = realpath($configured_path);
            // Canonical spelling rejects symlink components and dot segments.
            if (!$root || !$path || $path !== $configured_path
                || $path === $root || str_starts_with($path, rtrim($root, '/') . '/')) { return null; }
            clearstatcache(true, $path);
            $before = @lstat($path);
            if (!is_array($before) || ($before['mode'] & 0170000) !== 0100000
                || ($before['mode'] & 0077) !== 0 || $before['size'] !== 32) { return null; }
            $handle = @fopen($path, 'rb');
            if (!is_resource($handle)) { return null; }
            $opened = fstat($handle);
            if (!is_array($opened) || $opened['dev'] !== $before['dev']
                || $opened['ino'] !== $before['ino'] || $opened['mode'] !== $before['mode']
                || $opened['size'] !== 32) { return null; }
            $key = stream_get_contents($handle, 33);
            return is_string($key) && strlen($key) === 32 ? new self($key, $key_id) : null;
        } catch (Throwable $error) {
            return null;
        } finally {
            if (is_resource($handle)) { fclose($handle); }
            if (is_string($key) && function_exists('sodium_memzero')) { sodium_memzero($key); }
        }
    }

    /** Never persist an unkeyed fingerprint of guessable personal fields. */
    public function fingerprint($digest) {
        if (!is_string($digest) || preg_match('/^[a-f0-9]{64}$/D', $digest) !== 1) {
            throw new InvalidArgumentException('collaboration_payload_invalid');
        }
        return hash_hmac('sha256', 'yishu/collaboration/idempotency/v1|' . $digest, $this->key);
    }

    public function seal(#[\SensitiveParameter] $payload, $fan_user_id, $request_id) {
        $context = $this->context($fan_user_id, $request_id);
        $encoded = $this->encode_payload($payload);
        if ($context === null || $encoded === null) {
            throw new InvalidArgumentException('collaboration_payload_invalid');
        }
        try {
            $nonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
            $ciphertext = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
                $encoded, $context, $nonce, $this->key
            );
            return 'v1.' . $this->key_id . '.' . self::encode($nonce) . '.' . self::encode($ciphertext);
        } finally {
            sodium_memzero($encoded);
        }
    }

    /** No plaintext fallback on a damaged, swapped, legacy or unknown envelope. */
    public function open($envelope, $fan_user_id, $request_id) {
        $context = $this->context($fan_user_id, $request_id);
        if ($context === null || !is_string($envelope) || strlen($envelope) > 44000) { return null; }
        $parts = explode('.', $envelope);
        if (count($parts) !== 4 || $parts[0] !== 'v1' || $parts[1] !== $this->key_id) { return null; }
        $nonce = self::decode($parts[2]);
        $ciphertext = self::decode($parts[3]);
        if (!is_string($nonce) || strlen($nonce) !== SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES
            || !is_string($ciphertext) || strlen($ciphertext) < SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_ABYTES
            || strlen($ciphertext) > self::MAX_BYTES + SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_ABYTES) { return null; }
        $plaintext = false;
        try {
            $plaintext = sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
                $ciphertext, $context, $nonce, $this->key
            );
            if (!is_string($plaintext)) { return null; }
            $payload = json_decode($plaintext, true, 4, JSON_THROW_ON_ERROR);
            // Canonical field order also rejects duplicate/unknown JSON keys.
            return $this->encode_payload($payload) === $plaintext ? $payload : null;
        } catch (Throwable $error) {
            return null;
        } finally {
            if (is_string($plaintext)) { sodium_memzero($plaintext); }
        }
    }

    private function context($fan_user_id, $request_id) {
        if (!is_int($fan_user_id) || $fan_user_id <= 0 || !is_string($request_id)
            || preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/D', $request_id) !== 1) {
            return null;
        }
        return 'yishu/collaboration/private-payload/v1|' . $this->key_id . '|' . $fan_user_id . '|' . $request_id;
    }

    private function encode_payload(#[\SensitiveParameter] $payload) {
        if (!is_array($payload) || count($payload) !== count(self::FIELDS)) { return null; }
        $canonical = array();
        $bytes = 0;
        foreach (self::FIELDS as $field) {
            if (!array_key_exists($field, $payload)
                || (!is_string($payload[$field]) && !($field === 'preferredDate' && $payload[$field] === null))) {
                return null;
            }
            $bytes += is_string($payload[$field]) ? strlen($payload[$field]) : 0;
            if ($bytes > self::MAX_BYTES) { return null; }
            $canonical[$field] = $payload[$field];
        }
        $encoded = json_encode($canonical, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        return is_string($encoded) && strlen($encoded) <= self::MAX_BYTES ? $encoded : null;
    }

    private static function encode($bytes) { return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '='); }
    private static function decode($encoded) {
        if (!is_string($encoded) || preg_match('/^[A-Za-z0-9_-]+$/D', $encoded) !== 1) { return null; }
        $decoded = base64_decode(strtr($encoded, '-_', '+/') . str_repeat('=', (4 - strlen($encoded) % 4) % 4), true);
        return is_string($decoded) && self::encode($decoded) === $encoded ? $decoded : null;
    }
}
