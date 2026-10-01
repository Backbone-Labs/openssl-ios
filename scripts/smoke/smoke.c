// Functional smoke test for OpenSSLCrypto.xcframework. scripts/smoke-test.sh
// links it against each slice and runs the simulator build.
//
// It covers the primitives consumers rely on today (Neo-Fuji PIN pairing:
// SHA-256, HMAC-SHA-256, scrypt, base64, P-256 point arithmetic) using published
// test vectors, and checks that the headers and the library are the same
// OpenSSL release. EXPECTED_OPENSSL_VERSION is passed in by the script.
#include <openssl/bn.h>
#include <openssl/crypto.h>
#include <openssl/ec.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/obj_mac.h>
#include <openssl/rand.h>

#include <stdio.h>
#include <string.h>

#ifndef EXPECTED_OPENSSL_VERSION
#error "Build with -DEXPECTED_OPENSSL_VERSION=\"x.y.z\" (scripts/smoke-test.sh does)"
#endif

static int failures = 0;

static void check(int ok, const char *name) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    if (!ok) failures++;
}

static int hex_equals(const unsigned char *bytes, size_t length, const char *hex) {
    char encoded[2 * 64 + 1];
    if (length * 2 + 1 > sizeof(encoded)) return 0;
    for (size_t i = 0; i < length; i++) snprintf(encoded + 2 * i, 3, "%02x", bytes[i]);
    return strcmp(encoded, hex) == 0;
}

static void check_version(void) {
    check(strcmp(OpenSSL_version(OPENSSL_VERSION_STRING), OPENSSL_VERSION_STR) == 0 &&
              strcmp(OPENSSL_VERSION_STR, EXPECTED_OPENSSL_VERSION) == 0,
          "headers and library are OpenSSL " EXPECTED_OPENSSL_VERSION);
}

static void check_digests(void) {
    unsigned char digest[32];
    unsigned int digest_length = 0;
    check(EVP_Digest("abc", 3, digest, &digest_length, EVP_sha256(), NULL) == 1 && digest_length == 32 &&
              hex_equals(digest, 32, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
          "SHA-256 (FIPS 180-2 \"abc\")");

    unsigned char key[20];
    memset(key, 0x0b, sizeof(key));
    unsigned char mac[32];
    unsigned int mac_length = 0;
    check(HMAC(EVP_sha256(), key, (int)sizeof(key), (const unsigned char *)"Hi There", 8, mac, &mac_length) != NULL &&
              mac_length == 32 &&
              hex_equals(mac, 32, "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
          "HMAC-SHA-256 (RFC 4231 test case 1)");
}

static void check_scrypt(void) {
    unsigned char derived[64];
    check(EVP_PBE_scrypt("password", 8, (const unsigned char *)"NaCl", 4, 1024, 8, 16, 0, derived, sizeof(derived)) == 1 &&
              hex_equals(derived, 64,
                         "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162"
                         "2eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640"),
          "scrypt (RFC 7914 N=1024 r=8 p=16)");
}

static void check_base64(void) {
    unsigned char encoded[16] = {0};
    unsigned char decoded[16] = {0};
    check(EVP_EncodeBlock(encoded, (const unsigned char *)"foobar", 6) == 8 &&
              strcmp((const char *)encoded, "Zm9vYmFy") == 0 &&
              EVP_DecodeBlock(decoded, encoded, 8) == 6 && memcmp(decoded, "foobar", 6) == 0,
          "base64 round trip (RFC 4648 \"foobar\")");
}

static void check_p256(void) {
    // RFC 9382's M point for P-256, the SPAKE2 blinding point pairing uses.
    static const char *m_hex = "02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f";

    EC_GROUP *group = EC_GROUP_new_by_curve_name(NID_X9_62_prime256v1);
    BN_CTX *ctx = BN_CTX_new();
    BIGNUM *order = BN_new(), *two = BN_new(), *scalar = BN_new();
    EC_POINT *m = NULL, *a = NULL, *b = NULL;
    long m_length = 0;
    unsigned char *m_bytes = OPENSSL_hexstr2buf(m_hex, &m_length);

    int ready = group != NULL && ctx != NULL && order != NULL && two != NULL && scalar != NULL && m_bytes != NULL &&
                (m = EC_POINT_new(group)) != NULL && (a = EC_POINT_new(group)) != NULL &&
                (b = EC_POINT_new(group)) != NULL && EC_GROUP_get_order(group, order, ctx) == 1 &&
                BN_set_word(two, 2) == 1;
    check(ready, "P-256 group and points allocate");
    if (ready) {
        const EC_POINT *generator = EC_GROUP_get0_generator(group);

        check(EC_POINT_oct2point(group, m, m_bytes, (size_t)m_length, ctx) == 1 &&
                  EC_POINT_is_on_curve(group, m, ctx) == 1,
              "P-256 decodes RFC 9382 M and it is on the curve");

        check(EC_POINT_mul(group, a, two, NULL, NULL, ctx) == 1 &&
                  EC_POINT_add(group, b, generator, generator, ctx) == 1 &&
                  EC_POINT_cmp(group, a, b, ctx) == 0,
              "P-256 2*G equals G+G");

        check(EC_POINT_copy(b, m) == 1 && EC_POINT_invert(group, b, ctx) == 1 &&
                  EC_POINT_add(group, a, m, b, ctx) == 1 && EC_POINT_is_at_infinity(group, a) == 1,
              "P-256 M + (-M) is the point at infinity");

        check(EC_POINT_mul(group, a, order, NULL, NULL, ctx) == 1 && EC_POINT_is_at_infinity(group, a) == 1,
              "P-256 n*G is the point at infinity");

        check(BN_priv_rand_range(scalar, order) == 1 && BN_is_zero(scalar) == 0 &&
                  EC_POINT_mul(group, a, NULL, m, scalar, ctx) == 1 && EC_POINT_is_on_curve(group, a, ctx) == 1,
              "P-256 random scalar times M is on the curve");
    }

    OPENSSL_free(m_bytes);
    EC_POINT_free(m);
    EC_POINT_free(a);
    EC_POINT_free(b);
    BN_free(order);
    BN_free(two);
    BN_clear_free(scalar);
    BN_CTX_free(ctx);
    EC_GROUP_free(group);
}

static void check_random(void) {
    unsigned char first[32] = {0}, second[32] = {0};
    check(RAND_bytes(first, sizeof(first)) == 1 && RAND_bytes(second, sizeof(second)) == 1 &&
              memcmp(first, second, sizeof(first)) != 0,
          "RAND_bytes returns fresh output");
}

int main(void) {
    check_version();
    check_digests();
    check_scrypt();
    check_base64();
    check_p256();
    check_random();

    if (failures == 0) {
        printf("smoke: all checks passed\n");
        return 0;
    }
    printf("smoke: %d check(s) failed\n", failures);
    return 1;
}
