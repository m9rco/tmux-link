#include <stdint.h>
#include <stddef.h>
char *tl_connect(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed);
char *tl_open(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t target);
// For terminal targets, output is framed: kind (u8), size (u32 BE), payload.
// 0 = terminal bytes, 1 = UTF-8 stage, 2 = SSH RTT (u32 BE ms, UINT32_MAX if stale).
// Target -2 still returns unframed JSON. An identity requires both DER buffers and WSS.
char *tl_open_secure(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t target, const uint8_t *cert_der, size_t cert_len, const uint8_t *key_pkcs8, size_t key_len);
void tl_free_error(char *);
