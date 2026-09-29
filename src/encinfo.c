/* EncryptionInfo: the version prefix, then the agile XML descriptor.
 * See encinfo.h for the contract.
 *
 * [MS-OFFCRYPTO] 2.3.4.10 describes the descriptor as:
 *
 *   <encryption xmlns=".../2006/encryption" ...>
 *     <keyData saltSize blockSize keyBits hashSize cipherAlgorithm
 *              cipherChaining hashAlgorithm saltValue/>
 *     <dataIntegrity encryptedHmacKey encryptedHmacValue/>
 *     <keyEncryptors>
 *       <keyEncryptor uri=".../2006/keyEncryptor/password">
 *         <p:encryptedKey ...keyData's attributes... spinCount
 *              encryptedVerifierHashInput encryptedVerifierHashValue
 *              encryptedKeyValue/>
 *       </keyEncryptor>
 *     </keyEncryptors>
 *   </encryption>
 *
 * Elements are matched by namespace URI and local name, never by prefix:
 * Expat runs in namespace mode and reports "uri|local". A prefix is the
 * producer's choice, and matching on one is the mistake patch 0002 fixed in
 * xlsxio. A DOCTYPE is refused outright -- the descriptor has no use for
 * one, and zuxml's Expat already refuses every entity past the five
 * built-ins, so this only makes the refusal say what it is.
 */
#include "encinfo.h"

#include <expat.h>

#include <limits.h>
#include <stdlib.h>
#include <string.h>

#define NS_ENCRYPTION "http://schemas.microsoft.com/office/2006/encryption"
#define NS_PASSWORD "http://schemas.microsoft.com/office/2006/keyEncryptor/password"
#define NS_SEP '|'
#define MAX_DEPTH 64

enum { S_KD_CIPHER, S_KD_CHAINING, S_KD_HASH, S_PW_CIPHER, S_PW_CHAINING, S_PW_HASH };
enum { B_KD_SALT, B_HMAC_KEY, B_HMAC_VALUE, B_PW_SALT, B_VERIFIER_INPUT,
       B_VERIFIER_VALUE, B_KEY_VALUE };

typedef enum {
  K_OTHER = 0, K_ENCRYPTION, K_KEY_ENCRYPTORS, K_PASSWORD_ENCRYPTOR
} kind;

typedef struct {
  XML_Parser parser;
  encinfo *info;
  int depth;
  kind stack[MAX_DEPTH];
  int seen_key_data, seen_integrity, seen_password_key;
  int bad, memory, doctype;
} state;

/* "uri|local" against a namespace and a local name. */
static int is(const char *name, const char *ns, const char *local) {
  size_t n = strlen(ns);
  return strncmp(name, ns, n) == 0 && name[n] == NS_SEP &&
         strcmp(name + n + 1, local) == 0;
}

static const char *attr(const char **atts, const char *name) {
  for (; atts[0] != NULL; atts += 2) {
    if (strcmp(atts[0], name) == 0) return atts[1];
  }
  return NULL;
}

/* A decimal count: digits only, at most what a signed 32-bit value holds.
   -1 for anything else, which agile_decrypt() refuses. */
static long count(const char *s) {
  long v = 0;
  size_t i;

  if (s == NULL || s[0] == '\0') return -1;
  for (i = 0; s[i] != '\0'; i++) {
    if (s[i] < '0' || s[i] > '9' || i >= 10) return -1;
    v = v * 10 + (s[i] - '0');
  }
  return v > INT_MAX ? -1 : v;
}

static int b64_value(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

/* Strict base64 (RFC 4648 section 4): whole quanta, padding only at the end,
   nothing outside the alphabet. NULL with *len 0 for invalid input, and for
   an empty attribute, both of which agile_decrypt() refuses; *oom set if the
   allocation failed. */
static uint8_t *base64(const char *s, size_t *len, int *oom) {
  size_t n, i, o = 0, pad = 0;
  uint8_t *out;

  *len = 0;
  if (s == NULL) return NULL;
  n = strlen(s);
  if (n == 0 || n % 4 != 0) return NULL;
  if (s[n - 1] == '=') pad++;
  if (s[n - 2] == '=') pad++;
  out = malloc(n / 4 * 3);
  if (out == NULL) {
    *oom = 1;
    return NULL;
  }
  for (i = 0; i < n; i += 4) {
    int v[4], k;
    int last = i + 4 == n;
    for (k = 0; k < 4; k++) {
      if (last && s[i + k] == '=' && k >= 4 - (int) pad) {
        v[k] = 0;
      } else {
        v[k] = b64_value(s[i + k]);
        if (v[k] < 0) {
          free(out);
          return NULL;
        }
      }
    }
    out[o++] = (uint8_t) ((v[0] << 2) | (v[1] >> 4));
    if (!last || pad < 2) out[o++] = (uint8_t) (((v[1] & 0xF) << 4) | (v[2] >> 2));
    if (!last || pad < 1) out[o++] = (uint8_t) (((v[2] & 0x3) << 6) | v[3]);
  }
  *len = o;
  return out;
}

static char *copy(const char *s, int *oom) {
  char *out;
  if (s == NULL) return NULL;
  out = malloc(strlen(s) + 1);
  if (out == NULL) {
    *oom = 1;
    return NULL;
  }
  strcpy(out, s);
  return out;
}

/* The attributes <keyData> and <p:encryptedKey> share. */
static void read_cipher(state *st, const char **atts, agile_cipher *c,
                        int s_first, int b_salt) {
  encinfo *info = st->info;

  info->strings[s_first] = copy(attr(atts, "cipherAlgorithm"), &st->memory);
  info->strings[s_first + 1] = copy(attr(atts, "cipherChaining"), &st->memory);
  info->strings[s_first + 2] = copy(attr(atts, "hashAlgorithm"), &st->memory);
  c->cipher_algorithm = info->strings[s_first];
  c->cipher_chaining = info->strings[s_first + 1];
  c->hash_algorithm = info->strings[s_first + 2];
  c->salt_size = count(attr(atts, "saltSize"));
  c->block_size = count(attr(atts, "blockSize"));
  c->key_bits = count(attr(atts, "keyBits"));
  c->hash_size = count(attr(atts, "hashSize"));
  info->blobs[b_salt] = base64(attr(atts, "saltValue"), &c->salt_len, &st->memory);
  c->salt = info->blobs[b_salt];
}

static void XMLCALL on_start(void *data, const char *name, const char **atts) {
  state *st = (state *) data;
  agile_params *p = &st->info->params;
  kind parent = st->depth > 0 ? st->stack[st->depth - 1] : K_OTHER;
  kind k = K_OTHER;

  if (st->depth >= MAX_DEPTH) {
    st->bad = 1;
    XML_StopParser(st->parser, XML_FALSE);
    return;
  }

  if (st->depth == 0) {
    /* The document element, and nothing else, is <encryption>. */
    if (!is(name, NS_ENCRYPTION, "encryption")) st->bad = 1;
    k = K_ENCRYPTION;
  } else if (parent == K_ENCRYPTION && is(name, NS_ENCRYPTION, "keyData")) {
    if (st->seen_key_data++) st->bad = 1;
    else read_cipher(st, atts, &p->key_data, S_KD_CIPHER, B_KD_SALT);
  } else if (parent == K_ENCRYPTION && is(name, NS_ENCRYPTION, "dataIntegrity")) {
    if (st->seen_integrity++) {
      st->bad = 1;
    } else {
      st->info->blobs[B_HMAC_KEY] = base64(attr(atts, "encryptedHmacKey"),
                                           &p->encrypted_hmac_key_len, &st->memory);
      st->info->blobs[B_HMAC_VALUE] = base64(attr(atts, "encryptedHmacValue"),
                                             &p->encrypted_hmac_value_len, &st->memory);
      p->encrypted_hmac_key = st->info->blobs[B_HMAC_KEY];
      p->encrypted_hmac_value = st->info->blobs[B_HMAC_VALUE];
    }
  } else if (parent == K_ENCRYPTION && is(name, NS_ENCRYPTION, "keyEncryptors")) {
    k = K_KEY_ENCRYPTORS;
  } else if (parent == K_KEY_ENCRYPTORS && is(name, NS_ENCRYPTION, "keyEncryptor")) {
    /* Password, or certificate: only the first is something a password
       can open. */
    const char *uri = attr(atts, "uri");
    if (uri != NULL && strcmp(uri, NS_PASSWORD) == 0) k = K_PASSWORD_ENCRYPTOR;
  } else if (parent == K_PASSWORD_ENCRYPTOR && is(name, NS_PASSWORD, "encryptedKey")) {
    if (st->seen_password_key++) {
      st->bad = 1;
    } else {
      read_cipher(st, atts, &p->password, S_PW_CIPHER, B_PW_SALT);
      p->spin_count = count(attr(atts, "spinCount"));
      st->info->blobs[B_VERIFIER_INPUT] =
        base64(attr(atts, "encryptedVerifierHashInput"),
               &p->encrypted_verifier_hash_input_len, &st->memory);
      st->info->blobs[B_VERIFIER_VALUE] =
        base64(attr(atts, "encryptedVerifierHashValue"),
               &p->encrypted_verifier_hash_value_len, &st->memory);
      st->info->blobs[B_KEY_VALUE] =
        base64(attr(atts, "encryptedKeyValue"),
               &p->encrypted_key_value_len, &st->memory);
      p->encrypted_verifier_hash_input = st->info->blobs[B_VERIFIER_INPUT];
      p->encrypted_verifier_hash_value = st->info->blobs[B_VERIFIER_VALUE];
      p->encrypted_key_value = st->info->blobs[B_KEY_VALUE];
    }
  }
  /* Anything else is ignored: the schema is extensible, and an element this
     does not know cannot change what the ones it does know say. */

  st->stack[st->depth++] = k;
  if (st->bad || st->memory) XML_StopParser(st->parser, XML_FALSE);
}

static void XMLCALL on_end(void *data, const char *name) {
  state *st = (state *) data;
  (void) name;
  st->depth--;
}

static void XMLCALL on_doctype(void *data, const char *name, const char *sysid,
                               const char *pubid, int has_internal_subset) {
  state *st = (state *) data;
  (void) name; (void) sysid; (void) pubid; (void) has_internal_subset;
  st->doctype = 1;
  XML_StopParser(st->parser, XML_FALSE);
}

void encinfo_free(encinfo *info) {
  size_t i;
  for (i = 0; i < sizeof info->strings / sizeof *info->strings; i++) {
    free(info->strings[i]);
  }
  for (i = 0; i < sizeof info->blobs / sizeof *info->blobs; i++) {
    free(info->blobs[i]);
  }
  memset(info, 0, sizeof *info);
}

encinfo_status encinfo_parse(const uint8_t *stream, size_t len, encinfo *info) {
  state st;
  uint16_t major, minor;
  uint32_t flags;
  const char *xml;
  size_t left;
  int ok = 1;

  memset(info, 0, sizeof *info);
  info->params.spin_count = -1;
  if (stream == NULL || len < 8) return ENCINFO_MALFORMED;

  /* 2.3.4.10 and 2.3.4.5/6: 4.4 is agile, {2,3,4}.2 standard, {3,4}.3
     extensible. Agile's flags are reserved and fixed at 0x40. */
  major = (uint16_t) (stream[0] | (stream[1] << 8));
  minor = (uint16_t) (stream[2] | (stream[3] << 8));
  flags = (uint32_t) stream[4] | ((uint32_t) stream[5] << 8) |
          ((uint32_t) stream[6] << 16) | ((uint32_t) stream[7] << 24);
  if (minor == 2 && major >= 2 && major <= 4) return ENCINFO_STANDARD;
  if (minor == 3 && (major == 3 || major == 4)) return ENCINFO_EXTENSIBLE;
  if (major != 4 || minor != 4) return ENCINFO_UNKNOWN;
  if (flags != 0x40) return ENCINFO_MALFORMED;

  memset(&st, 0, sizeof st);
  st.info = info;
  st.parser = XML_ParserCreateNS(NULL, NS_SEP);
  if (st.parser == NULL) return ENCINFO_MEMORY;
  XML_SetUserData(st.parser, &st);
  XML_SetElementHandler(st.parser, on_start, on_end);
  XML_SetStartDoctypeDeclHandler(st.parser, on_doctype);

  /* XML_Parse takes an int length, so a long descriptor goes in pieces. */
  xml = (const char *) stream + 8;
  left = len - 8;
  do {
    int chunk = left > (size_t) (INT_MAX / 2) ? INT_MAX / 2 : (int) left;
    left -= (size_t) chunk;
    if (XML_Parse(st.parser, xml, chunk, left == 0) != XML_STATUS_OK) ok = 0;
    xml += chunk;
  } while (ok && left > 0);
  XML_ParserFree(st.parser);

  if (st.memory) {
    encinfo_free(info);
    return ENCINFO_MEMORY;
  }
  if (!ok || st.bad || st.doctype || !st.seen_key_data || !st.seen_integrity) {
    encinfo_free(info);
    return ENCINFO_MALFORMED;
  }
  if (!st.seen_password_key) {
    encinfo_free(info);
    return ENCINFO_NO_PASSWORD;
  }
  return ENCINFO_OK;
}
