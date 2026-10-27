"""The menu-bar app's Swift source: menu-bar-app/*.swift, one file per area."""

import glob
import os

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
# The order the code had as one file, so a test that cuts between two markers still works.
ORDER = ["Log", "Coach", "Pavlok", "Screenpipe", "Outbox", "Process", "Vault", "PavlokMenu", "Tray", "main"]
SWIFT_FILES = sorted(glob.glob(os.path.join(REPO, "menu-bar-app", "*.swift")),
                     key=lambda p: ORDER.index(os.path.basename(p)[:-6]) if os.path.basename(p)[:-6] in ORDER else len(ORDER))


def swift_source() -> str:
    """Every Swift file joined, for tests that look for code wherever it lives."""
    parts = []
    for path in SWIFT_FILES:
        with open(path, encoding="utf-8") as fh:
            parts.append(fh.read())
    return "\n".join(parts)
