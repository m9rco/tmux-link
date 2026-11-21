#include <stdint.h>
char *tl_connect(int fd, const char *host, uint16_t port, const char *user, const char *pin, const uint8_t *seed);
void tl_free_error(char *);
