#include <stdio.h>
#include <unistd.h>

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    fputs("\033[?1049h", stdout);
    for (;;) {
        /* Keep the same unanswered question visible in both phases. */
        fputs("\033[2J\033[HTL-SYNTHETIC-PHASE-RUN\r\n\r\n"
              "Earlier output: waiting for input.\r\nDo you want to proceed?\r\n\033[10;1H"
              "• Working (2s • esc to interrupt)", stdout);
        sleep(5);
        fputs("\033[2J\033[HTL-SYNTHETIC-PHASE-WAIT\r\n\r\n"
              "Do you want to proceed?\r\n"
              "❯ 1. Yes\r\n  2. No\r\nPress Enter to confirm", stdout);
        sleep(5);
    }
}
