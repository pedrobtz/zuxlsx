/* Agile encryption: key derivation, the verifier, dataIntegrity and the
 * segment loop, over zucrypt. See agile.h for the contract and design
 * section 21c for why only agile.
 *
 * References are to [MS-OFFCRYPTO] v20240416:
 *   2.3.4.10  the XML parameters and their permitted values
 *   2.3.4.11  deriving an encryption key from a password
 *   2.3.4.12  initialization vectors
 *   2.3.4.13  the password verifier and the intermediate key
 *   2.3.4.14  dataIntegrity
 *   2.3.4.15  the EncryptedPackage stream, in 4096-byte segments
 *
 * No R here. Every exit goes through one cleanup block that frees each
 * zucrypt handle and wipes every buffer that held key material, so an early
 * return cannot leak a key into freed memory.
 */
#include "agile.h"

#include <stdlib.h>
#include <string.h>

#define AGILE_SEGMENT 4096

/* 2.3.4.10 bounds. spinCount MUST NOT exceed 10,000,000, and the file says
 * how many to do, so this is also the only thing standing between a hostile
 * workbook and a very long wait. */
#define AGILE_MAX_SPIN 10000000L
#define AGILE_MAX_SALT 65536L

/* The blockKey constants of 2.3.4.13 and 2.3.4.14. */
static const uint8_t BLOCK_VERIFIER_INPUT[8] = {
  0xfe, 0xa7, 0xd2, 0x76, 0x3b, 0x4b, 0x9e, 0x79};
static const uint8_t BLOCK_VERIFIER_VALUE[8] = {
  0xd7, 0xaa, 0x0f, 0x6d, 0x30, 0x61, 0x34, 0x4e};
static const uint8_t BLOCK_KEY_VALUE[8] = {
  0x14, 0x6e, 0x0b, 0xe7, 0xab, 0xac, 0xd0, 0xd6};
static const uint8_t BLOCK_HMAC_KEY[8] = {
  0x5f, 0xb2, 0xad, 0x01, 0x0c, 0xb9, 0xe1, 0xf6};
static const uint8_t BLOCK_HMAC_VALUE[8] = {
  0xa0, 0x67, 0x7f, 0x02, 0xb2, 0x2c, 0x84, 0x33};

static zuc_status backend = ZUC_ERR_NOT_READY;

void agile_backend_init(void) {
  backend = zuc_init();
}

void agile_backend_shutdown(void) {
  if (backend == ZUC_OK) {
    zuc_shutdown();
    backend = ZUC_ERR_NOT_READY;
  }
}

zuc_status agile_backend_status(void) {
  return backend;
}

/* One agile_cipher, checked and resolved. */
typedef struct {
  zuc_alg hash;
  size_t hash_size;
  size_t key_len;
  const uint8_t *salt;
  size_t salt_len;
} cipher;

static zuc_alg hash_by_name(const char *name) {
  /* 2.3.4.10 spells SHA-1 with a hyphen and the others without; msoffcrypto
     and Excel both write "SHA512". Anything else the spec permits (MD5, MD4,
     MD2, RIPEMD-128, RIPEMD-160, WHIRLPOOL) is refused as unsupported. */
  if (strcmp(name, "SHA-1") == 0 || strcmp(name, "SHA1") == 0) return ZUC_ALG_SHA1;
  if (strcmp(name, "SHA256") == 0) return ZUC_ALG_SHA256;
  if (strcmp(name, "SHA384") == 0) return ZUC_ALG_SHA384;
  if (strcmp(name, "SHA512") == 0) return ZUC_ALG_SHA512;
  return ZUC_ALG_NONE;
}

/* Names are checked before sizes. A well-formed description of a cipher this
   does not implement is unsupported, whatever its sizes say -- and a size
   that contradicts the named algorithm is malformed, never a reason to guess
   another algorithm. Deriving a key with the wrong algorithm and reporting a
   wrong password is the failure design section 21c exists to prevent. */
static agile_status resolve(const agile_cipher *in, cipher *out) {
  zuc_alg hash;

  if (in->cipher_algorithm == NULL || in->cipher_chaining == NULL ||
      in->hash_algorithm == NULL) {
    return AGILE_MALFORMED;
  }
  if (strcmp(in->cipher_algorithm, "AES") != 0) return AGILE_UNSUPPORTED;
  if (strcmp(in->cipher_chaining, "ChainingModeCBC") != 0) return AGILE_UNSUPPORTED;
  hash = hash_by_name(in->hash_algorithm);
  if (hash == ZUC_ALG_NONE || !zuc_alg_available(hash)) return AGILE_UNSUPPORTED;

  if (in->block_size != ZUC_AES_BLOCK_SIZE) return AGILE_MALFORMED;
  if (in->key_bits != 128 && in->key_bits != 192 && in->key_bits != 256) {
    return AGILE_MALFORMED;
  }
  if (in->hash_size != (long) zuc_alg_size(hash)) return AGILE_MALFORMED;
  if (in->salt == NULL || in->salt_size < 1 || in->salt_size > AGILE_MAX_SALT ||
      (size_t) in->salt_size != in->salt_len) {
    return AGILE_MALFORMED;
  }

  out->hash = hash;
  out->hash_size = (size_t) in->hash_size;
  out->key_len = (size_t) in->key_bits / 8;
  out->salt = in->salt;
  out->salt_len = in->salt_len;
  return AGILE_OK;
}

/* An encrypted field must be whole blocks and at least as long as what it
   decrypts to. */
static int field_ok(const uint8_t *p, size_t len, size_t at_least) {
  return p != NULL && len > 0 && len % ZUC_AES_BLOCK_SIZE == 0 && len >= at_least;
}

/* 2.3.4.11: a password is hashed as UTF-16LE. Strict UTF-8: overlong forms,
   surrogates and anything past U+10FFFF are refused rather than repaired,
   because a repaired password is a different password. */
static agile_status utf16le(const char *s, size_t n, uint8_t **out, size_t *out_len) {
  const unsigned char *p = (const unsigned char *) s;
  uint8_t *buf;
  size_t i = 0, o = 0;

  /* Every UTF-8 byte becomes at most two bytes of UTF-16. */
  if (n > (SIZE_MAX - 1) / 2) return AGILE_MEMORY;
  buf = malloc(n * 2 + 1);
  if (buf == NULL) return AGILE_MEMORY;

  while (i < n) {
    uint32_t cp;
    size_t extra, k;
    unsigned char c = p[i];

    if (c < 0x80) { cp = c; extra = 0; }
    else if (c >= 0xC2 && c <= 0xDF) { cp = c & 0x1F; extra = 1; }
    else if (c >= 0xE0 && c <= 0xEF) { cp = c & 0x0F; extra = 2; }
    else if (c >= 0xF0 && c <= 0xF4) { cp = c & 0x07; extra = 3; }
    else goto invalid;

    if (extra > n - i - 1) goto invalid;
    for (k = 1; k <= extra; k++) {
      if ((p[i + k] & 0xC0) != 0x80) goto invalid;
      cp = (cp << 6) | (p[i + k] & 0x3F);
    }
    if ((extra == 2 && cp < 0x800) || (extra == 3 && cp < 0x10000) ||
        (cp >= 0xD800 && cp <= 0xDFFF) || cp > 0x10FFFF) {
      goto invalid;
    }
    i += extra + 1;

    if (cp >= 0x10000) {
      uint32_t hi = 0xD800 + ((cp - 0x10000) >> 10);
      uint32_t lo = 0xDC00 + ((cp - 0x10000) & 0x3FF);
      buf[o++] = (uint8_t) (hi & 0xFF);
      buf[o++] = (uint8_t) (hi >> 8);
      buf[o++] = (uint8_t) (lo & 0xFF);
      buf[o++] = (uint8_t) (lo >> 8);
    } else {
      buf[o++] = (uint8_t) (cp & 0xFF);
      buf[o++] = (uint8_t) (cp >> 8);
    }
  }

  *out = buf;
  *out_len = o;
  return AGILE_OK;

invalid:
  zuc_secure_zero(buf, n * 2 + 1);
  free(buf);
  return AGILE_BAD_PASSWORD;
}

static void le32(uint32_t v, uint8_t *out) {
  out[0] = (uint8_t) (v & 0xFF);
  out[1] = (uint8_t) ((v >> 8) & 0xFF);
  out[2] = (uint8_t) ((v >> 16) & 0xFF);
  out[3] = (uint8_t) ((v >> 24) & 0xFF);
}

/* H(a || b), reusing one handle. */
static zuc_status hash2(zuc_hash *h, const uint8_t *a, size_t a_len,
                        const uint8_t *b, size_t b_len,
                        uint8_t *out, size_t hash_size) {
  size_t n = 0;
  zuc_status st = zuc_hash_reset(h);
  if (st == ZUC_OK) st = zuc_hash_update(h, a, a_len);
  if (st == ZUC_OK) st = zuc_hash_update(h, b, b_len);
  if (st == ZUC_OK) st = zuc_hash_finish(h, out, ZUC_MAX_DIGEST_SIZE, &n);
  if (st == ZUC_OK && n != hash_size) st = ZUC_ERR_INTERNAL;
  return st;
}

/* 2.3.4.11 and 2.3.4.12: a derived key or IV is the hash truncated to the
   length wanted, or padded with 0x36 when the hash is shorter. */
static void fit(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len) {
  if (in_len >= out_len) {
    memcpy(out, in, out_len);
  } else {
    memcpy(out, in, in_len);
    memset(out + in_len, 0x36, out_len - in_len);
  }
}

static zuc_status cbc_decrypt(const uint8_t *key, size_t key_len,
                              const uint8_t *iv,
                              const uint8_t *in, size_t len, uint8_t *out) {
  zuc_aes *aes = NULL;
  zuc_status st = zuc_aes_new(key, key_len, &aes);
  if (st == ZUC_OK) st = zuc_aes_cbc_set_state(aes, iv);
  if (st == ZUC_OK) st = zuc_aes_cbc_decrypt(aes, in, len, out);
  zuc_aes_free(aes);
  return st;
}

agile_status agile_package_size(const uint8_t *package, size_t package_len,
                                size_t *size) {
  uint64_t declared = 0;
  size_t avail;
  int i;

  if (package == NULL || package_len < 8) return AGILE_MALFORMED;
  for (i = 7; i >= 0; i--) declared = (declared << 8) | package[i];

  /* The ciphertext for `declared` bytes is that many rounded up to a block;
     compared without rounding up, which could overflow. */
  avail = package_len - 8;
  if (declared > (uint64_t) avail) return AGILE_MALFORMED;
  if (declared % ZUC_AES_BLOCK_SIZE != 0 &&
      avail - (size_t) declared < ZUC_AES_BLOCK_SIZE - declared % ZUC_AES_BLOCK_SIZE) {
    return AGILE_MALFORMED;
  }
  *size = (size_t) declared;
  return AGILE_OK;
}

agile_status agile_decrypt(const agile_params *params,
                           const char *password, size_t password_len,
                           const uint8_t *package, size_t package_len,
                           uint8_t *out, size_t out_len,
                           zuc_status *crypto) {
  agile_status res = AGILE_OK;
  zuc_status st = ZUC_OK;
  cipher kd, pw;
  size_t size = 0, scratch_len, off;
  uint8_t *pw16 = NULL, *scratch = NULL;
  size_t pw16_len = 0;
  zuc_hash *h = NULL;
  zuc_aes *aes = NULL;
  uint32_t i, seg;
  uint8_t iter[4];
  uint8_t digest[ZUC_MAX_DIGEST_SIZE];
  uint8_t digest2[ZUC_MAX_DIGEST_SIZE];
  uint8_t key[ZUC_AES_KEY_SIZE_256];
  uint8_t secret[ZUC_AES_KEY_SIZE_256];
  uint8_t hmac_key[ZUC_MAX_DIGEST_SIZE];
  uint8_t iv[ZUC_AES_BLOCK_SIZE];
  uint8_t block[ZUC_AES_BLOCK_SIZE];

  *crypto = ZUC_OK;
  if (backend != ZUC_OK) {
    *crypto = backend;
    return AGILE_CRYPTO;
  }

  /* Everything the file says is checked before any of it is used. */
  if ((res = resolve(&params->key_data, &kd)) != AGILE_OK) return res;
  if ((res = resolve(&params->password, &pw)) != AGILE_OK) return res;
  if (params->spin_count < 0 || params->spin_count > AGILE_MAX_SPIN) {
    return AGILE_MALFORMED;
  }
  if (!field_ok(params->encrypted_verifier_hash_input,
                params->encrypted_verifier_hash_input_len, pw.salt_len) ||
      !field_ok(params->encrypted_verifier_hash_value,
                params->encrypted_verifier_hash_value_len, pw.hash_size) ||
      !field_ok(params->encrypted_key_value,
                params->encrypted_key_value_len, kd.key_len) ||
      !field_ok(params->encrypted_hmac_key,
                params->encrypted_hmac_key_len, kd.hash_size) ||
      !field_ok(params->encrypted_hmac_value,
                params->encrypted_hmac_value_len, kd.hash_size)) {
    return AGILE_MALFORMED;
  }
  if ((res = agile_package_size(package, package_len, &size)) != AGILE_OK) return res;
  if (out_len != size || (size > 0 && out == NULL)) return AGILE_MALFORMED;

  /* One scratch buffer, big enough for whichever encrypted field is longest. */
  scratch_len = params->encrypted_verifier_hash_input_len;
  if (params->encrypted_verifier_hash_value_len > scratch_len)
    scratch_len = params->encrypted_verifier_hash_value_len;
  if (params->encrypted_key_value_len > scratch_len)
    scratch_len = params->encrypted_key_value_len;
  if (params->encrypted_hmac_key_len > scratch_len)
    scratch_len = params->encrypted_hmac_key_len;
  if (params->encrypted_hmac_value_len > scratch_len)
    scratch_len = params->encrypted_hmac_value_len;
  scratch = malloc(scratch_len);
  if (scratch == NULL) { res = AGILE_MEMORY; goto done; }

  if ((res = utf16le(password, password_len, &pw16, &pw16_len)) != AGILE_OK) goto done;

  /* 2.3.4.11: H0 = H(salt || password), then H(n) = H(iterator || H(n-1)).
     One handle, reset between rounds. */
  if ((st = zuc_hash_new(pw.hash, &h)) != ZUC_OK) goto done;
  if ((st = hash2(h, pw.salt, pw.salt_len, pw16, pw16_len, digest, pw.hash_size))
      != ZUC_OK) goto done;
  for (i = 0; i < (uint32_t) params->spin_count; i++) {
    le32(i, iter);
    if ((st = hash2(h, iter, 4, digest, pw.hash_size, digest, pw.hash_size))
        != ZUC_OK) goto done;
  }

  /* 2.3.4.13: the verifier. Three keys from the same H(n), one per blockKey,
     each decrypting with the password salt as IV. */
  fit(pw.salt, pw.salt_len, iv, sizeof iv);

  if ((st = hash2(h, digest, pw.hash_size, BLOCK_VERIFIER_INPUT, 8,
                  digest2, pw.hash_size)) != ZUC_OK) goto done;
  fit(digest2, pw.hash_size, key, pw.key_len);
  if ((st = cbc_decrypt(key, pw.key_len, iv,
                        params->encrypted_verifier_hash_input,
                        params->encrypted_verifier_hash_input_len, scratch))
      != ZUC_OK) goto done;
  /* The verifier input is saltSize random bytes; its hash is what the next
     field holds. */
  {
    size_t n = 0;
    uint8_t verifier_hash[ZUC_MAX_DIGEST_SIZE];

    if ((st = zuc_hash_compute(pw.hash, scratch, pw.salt_len, verifier_hash,
                               sizeof verifier_hash, &n)) != ZUC_OK) goto done;
    if ((st = hash2(h, digest, pw.hash_size, BLOCK_VERIFIER_VALUE, 8,
                    digest2, pw.hash_size)) != ZUC_OK) goto done;
    fit(digest2, pw.hash_size, key, pw.key_len);
    if ((st = cbc_decrypt(key, pw.key_len, iv,
                          params->encrypted_verifier_hash_value,
                          params->encrypted_verifier_hash_value_len, scratch))
        != ZUC_OK) goto done;
    if (n != pw.hash_size || !zuc_equal(verifier_hash, scratch, pw.hash_size)) {
      zuc_secure_zero(verifier_hash, sizeof verifier_hash);
      res = AGILE_WRONG_PASSWORD;
      goto done;
    }
    zuc_secure_zero(verifier_hash, sizeof verifier_hash);
  }

  /* The intermediate key: what actually encrypts the package. */
  if ((st = hash2(h, digest, pw.hash_size, BLOCK_KEY_VALUE, 8,
                  digest2, pw.hash_size)) != ZUC_OK) goto done;
  fit(digest2, pw.hash_size, key, pw.key_len);
  if ((st = cbc_decrypt(key, pw.key_len, iv,
                        params->encrypted_key_value,
                        params->encrypted_key_value_len, scratch)) != ZUC_OK) goto done;
  memcpy(secret, scratch, kd.key_len);

  /* From here on every hash is keyData's, which need not be the password
     encryptor's. */
  zuc_hash_free(h);
  h = NULL;
  if ((st = zuc_hash_new(kd.hash, &h)) != ZUC_OK) goto done;

  /* 2.3.4.14: dataIntegrity, checked over the whole EncryptedPackage stream
     -- length prefix included -- before a byte of it is decrypted. */
  if ((st = hash2(h, kd.salt, kd.salt_len, BLOCK_HMAC_KEY, 8,
                  digest2, kd.hash_size)) != ZUC_OK) goto done;
  fit(digest2, kd.hash_size, iv, sizeof iv);
  if ((st = cbc_decrypt(secret, kd.key_len, iv,
                        params->encrypted_hmac_key,
                        params->encrypted_hmac_key_len, scratch)) != ZUC_OK) goto done;
  memcpy(hmac_key, scratch, kd.hash_size);

  if ((st = hash2(h, kd.salt, kd.salt_len, BLOCK_HMAC_VALUE, 8,
                  digest2, kd.hash_size)) != ZUC_OK) goto done;
  fit(digest2, kd.hash_size, iv, sizeof iv);
  if ((st = cbc_decrypt(secret, kd.key_len, iv,
                        params->encrypted_hmac_value,
                        params->encrypted_hmac_value_len, scratch)) != ZUC_OK) goto done;
  {
    size_t n = 0;
    if ((st = zuc_hmac_compute(kd.hash, hmac_key, kd.hash_size,
                               package, package_len,
                               digest2, sizeof digest2, &n)) != ZUC_OK) goto done;
    if (n != kd.hash_size || !zuc_equal(digest2, scratch, kd.hash_size)) {
      res = AGILE_INTEGRITY;
      goto done;
    }
  }

  /* 2.3.4.15: 4096-byte segments, CBC restarted at each with
     IV = H(keyData salt || segment number). The last segment is padded to a
     whole block; the padding is decrypted into `block` and dropped. */
  if ((st = zuc_aes_new(secret, kd.key_len, &aes)) != ZUC_OK) goto done;
  for (seg = 0, off = 0; off < size; seg++, off += AGILE_SEGMENT) {
    size_t chunk = size - off < AGILE_SEGMENT ? size - off : AGILE_SEGMENT;
    size_t whole = chunk - chunk % ZUC_AES_BLOCK_SIZE;
    const uint8_t *ct = package + 8 + off;

    le32(seg, iter);
    if ((st = hash2(h, kd.salt, kd.salt_len, iter, 4, digest2, kd.hash_size))
        != ZUC_OK) goto done;
    fit(digest2, kd.hash_size, iv, sizeof iv);
    if ((st = zuc_aes_cbc_set_state(aes, iv)) != ZUC_OK) goto done;
    if ((st = zuc_aes_cbc_decrypt(aes, ct, whole, out + off)) != ZUC_OK) goto done;
    if (whole < chunk) {
      if ((st = zuc_aes_cbc_decrypt(aes, ct + whole, ZUC_AES_BLOCK_SIZE, block))
          != ZUC_OK) goto done;
      memcpy(out + off + whole, block, chunk - whole);
    }
  }

done:
  if (st != ZUC_OK) {
    *crypto = st;
    res = st == ZUC_ERR_MEMORY ? AGILE_MEMORY : AGILE_CRYPTO;
  }
  zuc_aes_free(aes);
  zuc_hash_free(h);
  if (pw16 != NULL) {
    zuc_secure_zero(pw16, pw16_len);
    free(pw16);
  }
  if (scratch != NULL) {
    zuc_secure_zero(scratch, scratch_len);
    free(scratch);
  }
  zuc_secure_zero(digest, sizeof digest);
  zuc_secure_zero(digest2, sizeof digest2);
  zuc_secure_zero(key, sizeof key);
  zuc_secure_zero(secret, sizeof secret);
  zuc_secure_zero(hmac_key, sizeof hmac_key);
  zuc_secure_zero(iv, sizeof iv);
  zuc_secure_zero(block, sizeof block);
  return res;
}
