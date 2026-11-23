"""Render a distinct reply to each test keystroke in a disposable tmux pane."""

import os
import signal
import sys
import termios
import tty


def main():
    fd = sys.stdin.fileno()
    original = termios.tcgetattr(fd)
    resize_count = 0

    def resized(_signal, _frame):
        nonlocal resize_count
        resize_count += 1

    signal.signal(signal.SIGWINCH, resized)
    try:
        tty.setraw(fd)
        os.write(1, b"\x1b[2J\x1b[HTL-READY")
        sequence = 0
        while key := os.read(fd, 1):
            if key == b"z":
                sequence = 0
                reply = b"TL-WARM"
            elif b"a" <= key <= b"y":
                sequence += 1
                reply = b"TL-%03d-%s" % (sequence, key)
            elif key in (b"^", b"$"):
                row = 1 if key == b"^" else os.get_terminal_size(fd).lines
                marker = b"TL-TOP" if key == b"^" else b"TL-BOTTOM"
                os.write(1, b"\x1b[?25h\x1b[%d;1H\x1b[2K%s" % (row, marker))
                continue
            elif key in (b"{", b"}"):
                hidden = key == b"}"
                first = os.get_terminal_size(fd).lines - 5
                lines = [b"+---TL-EDITOR-TOP---+", b"| > prompt          |",
                         b"|   second line     |", b"|   third line      |",
                         b"+--TL-EDITOR-END----+", b"TL-FOOTER-" + (b"HIDDEN" if hidden else b"VISIBLE")]
                if hidden:
                    lines[1] = b"| > prompt_         |"  # The application draws its own caret.
                frame = b"".join(b"\x1b[%d;1H\x1b[2K%s" % (first + i, line) for i, line in enumerate(lines))
                cursor = b"\x1b[H\x1b[?25l" if hidden else b"\x1b[%d;11H\x1b[?25h" % (first + 1)
                os.write(1, frame + cursor)
                continue
            elif key in (b"<", b">"):
                cols, rows = os.get_terminal_size(fd)
                reply = b"\x1b[?25hTL-PTY%s%d,%d,%d" % (key, resize_count, cols, rows)
            else:
                continue
            os.write(1, b"\x1b[2;1H\x1b[2K" + reply)
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, original)


if __name__ == "__main__":
    main()
