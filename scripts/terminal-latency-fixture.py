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
            elif key in (b"<", b">"):
                cols, rows = os.get_terminal_size(fd)
                reply = b"TL-PTY%s%d,%d,%d" % (key, resize_count, cols, rows)
            else:
                continue
            os.write(1, b"\x1b[2;1H\x1b[2K" + reply)
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, original)


if __name__ == "__main__":
    main()
