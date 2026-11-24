"""Checks that firmware/glove-left/ and firmware/glove-right/ are the same
code: only hand.h (and the .ino file name) may differ. Run after any firmware
edit:  python firmware/check_same.py   (exit 1 lists what differs)."""
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SIDES = {"left": 0, "right": 1}


def files(side):
    d = os.path.join(ROOT, "glove-" + side)
    return {("glove.ino" if n == f"glove-{side}.ino" else n): os.path.join(d, n)
            for n in os.listdir(d) if os.path.isfile(os.path.join(d, n))}


def read(p):
    with open(p, "rb") as f:
        return f.read().replace(b"\r\n", b"\n")


def main():
    left, right = files("left"), files("right")
    problems = []
    for name in sorted(set(left) | set(right)):
        if name not in left or name not in right:
            problems.append(f"{name}: only in glove-{'left' if name in left else 'right'}/")
        elif name != "hand.h" and read(left[name]) != read(right[name]):
            problems.append(f"{name}: differs - copy the change to the other glove")
    for side, want in SIDES.items():
        p = files(side).get("hand.h")
        m = p and re.search(rb"^#define HAND (\d)\b", read(p), re.M)
        if not m or int(m.group(1)) != want:
            problems.append(f"glove-{side}/hand.h: must say #define HAND {want}")
    for p in problems:
        print("DIFFERENT:", p)
    print("glove-left and glove-right match" if not problems else
          f"{len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
