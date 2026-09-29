/* Agile encryption ([MS-OFFCRYPTO] 2.3.4.10 to 2.3.4.15): the decryption core.
 *
 * Plain C over zucrypt. Nothing here includes an R header or calls into R, so
 * nothing here can longjmp: every zucrypt handle is created and freed inside
 * one call, and key material is wiped on every path out. That is also what
 * lets tools/fuzz drive it outside R (#45).
 *
 * The parameters are what EncryptionInfo's XML carries, already base64-decoded.
 * Where they come from is not this layer's business: today the tests read them
 * in R, later the reader parses them with Expat. Either way they are hostile
 * input, and agile_decrypt() checks every one of them before using it.
 */
#ifndef ZUXLSX_AGILE_H
#define ZUXLSX_AGILE_H

#include <stddef.h>
#include <stdint.h>

#include <zucrypt.h>

/* One <keyData> or <p:encryptedKey>: the attributes the two share. */
typedef struct {
  const char *cipher_algorithm;  /* "AES" is the only one supported */
  const char *cipher_chaining;   /* "ChainingModeCBC" is the only one supported */
  const char *hash_algorithm;    /* "SHA1", "SHA256", "SHA384" or "SHA512" */
  long salt_size;                /* declared; must match the salt's length */
  long block_size;
  long key_bits;
  long hash_size;
  const uint8_t *salt;
  size_t salt_len;
} agile_cipher;

typedef struct {
  agile_cipher key_data;

  /* <dataIntegrity> */
  const uint8_t *encrypted_hmac_key;
  size_t encrypted_hmac_key_len;
  const uint8_t *encrypted_hmac_value;
  size_t encrypted_hmac_value_len;

  /* <p:encryptedKey> */
  agile_cipher password;
  long spin_count;
  const uint8_t *encrypted_verifier_hash_input;
  size_t encrypted_verifier_hash_input_len;
  const uint8_t *encrypted_verifier_hash_value;
  size_t encrypted_verifier_hash_value_len;
  const uint8_t *encrypted_key_value;
  size_t encrypted_key_value_len;
} agile_params;

typedef enum {
  AGILE_OK = 0,
  AGILE_WRONG_PASSWORD,  /* the verifier did not match */
  AGILE_INTEGRITY,       /* dataIntegrity's HMAC did not match the package */
  AGILE_MALFORMED,       /* a parameter or the package is inconsistent */
  AGILE_UNSUPPORTED,     /* well formed, but an algorithm this does not do */
  AGILE_BAD_PASSWORD,    /* the password is not valid UTF-8 */
  AGILE_MEMORY,
  AGILE_CRYPTO           /* zucrypt refused; see the zuc_status alongside */
} agile_status;

/* The backend's lifetime, taken once when the DLL loads and dropped when it
 * unloads. A failed zuc_init() is remembered rather than raised -- R_init_
 * must not longjmp -- and agile_decrypt() reports it as AGILE_CRYPTO with
 * ZUC_ERR_NOT_READY. */
void agile_backend_init(void);
void agile_backend_shutdown(void);
zuc_status agile_backend_status(void);

/* The plaintext length an EncryptedPackage stream declares, checked against
 * the ciphertext actually present, so a caller can allocate the output before
 * calling agile_decrypt(). The declared length comes from the file, so it is
 * never trusted further than the bytes behind it. */
agile_status agile_package_size(const uint8_t *package, size_t package_len,
                                size_t *size);

/* Decrypts the EncryptedPackage stream `package` (the whole stream, starting
 * with its eight-byte length) into `out`, which must hold the length
 * agile_package_size() reported.
 *
 * Order matters and is the point: the password is checked against the
 * verifier, then the HMAC over the ciphertext is checked, and only then is
 * anything decrypted into `out`. A file that fails either check leaves `out`
 * untouched, so tampered ciphertext is never handed on as plaintext.
 *
 * `password` is UTF-8 and is encoded to UTF-16LE here, as the format
 * requires. On AGILE_CRYPTO, *crypto says what zucrypt reported. */
agile_status agile_decrypt(const agile_params *params,
                           const char *password, size_t password_len,
                           const uint8_t *package, size_t package_len,
                           uint8_t *out, size_t out_len,
                           zuc_status *crypto);

#endif
