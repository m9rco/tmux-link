#include <stdint.h>
#include <stddef.h>
char *tl_connect(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed);
char *tl_open(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t target);
// For terminal targets, output is framed: kind (u8), size (u32 BE), payload.
// 0 = terminal bytes, 1 = UTF-8 stage, 2 = SSH RTT (u32 BE ms, UINT32_MAX if stale),
// 3 = a page request failed (empty payload, terminal stays connected).
// Target -2 returns the session list as unframed JSON. Targets (-3 - sessionID)
// read unframed snapshot JSON for IDs in 0...INT64_MAX-2. Both operations are
// non-PTY SSH execs. An identity requires both DER buffers and WSS.
char *tl_open_secure(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t target, const uint8_t *cert_der, size_t cert_len, const uint8_t *key_pkcs8, size_t key_len);
// The terminal UI replies to the "attaching" stage with its first measured resize.
char *tl_open_secure_fitted(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t target, const uint8_t *cert_der, size_t cert_len, const uint8_t *key_pkcs8, size_t key_len);
void tl_free_error(char *);
// Returns NULL after approved host reports an outbound tunnel, otherwise an owned error string.
char *tl_approve_pairing(const char *url, const char *id, const char *request_json, const uint8_t *cert_der, size_t cert_len, const uint8_t *key_pkcs8, size_t key_len);
