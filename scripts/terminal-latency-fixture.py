"""Render a distinct reply to each test keystroke in a disposable tmux pane."""

import os
import sys
import termios
import tty


def main():
    fd = sys.stdin.fileno()
    original = termios.tcgetattr(fd)
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
            else:
                continue
            os.write(1, b"\x1b[2;1H\x1b[2K" + reply)
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, original)


if __name__ == "__main__":
    main()
