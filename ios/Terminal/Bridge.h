#include <stdint.h>
char *tl_connect(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed);
char *tl_open(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed, int64_t target);
void tl_free_error(char *);
