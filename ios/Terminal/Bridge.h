#include <stdint.h>
#include <stddef.h>
char *tl_connect(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed);
char *tl_open(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t target);
// For terminal targets, output is framed: kind (u8), size (u32 BE), payload.
// 0 = terminal bytes, 1 = UTF-8 stage, 2 = SSH RTT (u32 BE ms, UINT32_MAX if stale),
// 3 = a page request failed (empty), 4 = tracked tmux client PID (u32 BE).
// Target -2 returns the session list as unframed JSON. Targets (-3 - sessionID)
// read unframed snapshot JSON for IDs in 0...INT64_MAX-2. Both operations are
// non-PTY SSH execs. An identity requires both DER buffers and WSS.
char *tl_open_secure(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t target, const uint8_t *cert_der, size_t cert_len, const uint8_t *key_pkcs8, size_t key_len);
// The terminal UI replies to the "attaching" stage with its first measured resize.
char *tl_open_secure_fitted(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t target, const uint8_t *cert_der, size_t cert_len, const uint8_t *key_pkcs8, size_t key_len);
// A zero client PID starts a fitted, tracked attach. A positive PID reads its current pane context as JSON.
char *tl_agent_context_secure(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t session_id, uint32_t client_pid, const uint8_t *cert_der, size_t cert_len, const uint8_t *key_pkcs8, size_t key_len);
// Read one v2 snapshot as unframed JSON, using the nonnegative session ID directly.
char *tl_snapshot_v2_secure(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t session_id, const uint8_t *cert_der, size_t cert_len, const uint8_t *key_pkcs8, size_t key_len);
// Manage one session over pinned SSH. Remote credentials are never returned.
char *tl_managed_secure(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t session_id, const char *action, const uint8_t *cert_der, size_t cert_len, const uint8_t *key_pkcs8, size_t key_len);
// A NULL ticket claims a prompt. A finish sends the JSON reply as SSH stdin.
char *tl_advice_secure(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t session_id, const char *instance, const char *ticket, const uint8_t *payload, size_t size, const uint8_t *cert_der, size_t cert_len, const uint8_t *key_pkcs8, size_t key_len);
// Owns both distinct descriptors. Reads a regular file from offset zero. Shutdown the
// socket peer to cancel; on success the socket receives one unframed {path,bytes} receipt.
char *tl_upload_secure(int fd, int file_fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t session_id, const char *instance, const char *directory, const char *name, uint64_t size, const uint8_t *cert_der, size_t cert_len, const uint8_t *key_pkcs8, size_t key_len);
void tl_free_error(char *);
// Returns NULL after approved host reports an outbound tunnel, otherwise an owned error string.
char *tl_approve_pairing(const char *url, const char *id, const char *request_json, const uint8_t *cert_der, size_t cert_len, const uint8_t *key_pkcs8, size_t key_len);
