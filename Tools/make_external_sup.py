#!/usr/bin/env python3
"""Generate the independent raw SUP fixture for external loading tests."""

import sys

from make_pgs import main


EVENTS = [
    (2.0, 3.5, 110, 200, 100, 20, (235, 128, 128, 255), False),
    (4.0, 5.0, 40, 20, 60, 30, (81, 240, 90, 128), True),
]


if __name__ == "__main__":
    main(sys.argv[1], events=EVENTS)
