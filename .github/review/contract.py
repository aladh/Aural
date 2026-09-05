"""Pure path and diff-anchor validation for native review publication."""

import re
from pathlib import PurePosixPath


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_path(name):
    """Return whether *name* is a safe repository-relative POSIX path."""
    if not isinstance(name, str):
        return False
    path = PurePosixPath(name)
    return bool(name) and not path.is_absolute() and ".." not in path.parts \
        and "\\" not in name and all(ord(char) >= 32 for char in name) and ".git" not in path.parts


def _diff_right_lines(diff):
    """Right-side ranges from a single file's diff, independent of quoted Git path headers."""
    anchors = set()
    for match in re.finditer(rb'^@@ -[0-9]+(?:,[0-9]+)? \+([0-9]+)(?:,([0-9]+))? @@', diff, re.MULTILINE):
        start = int(match[1])
        count = int(match[2]) if match[2] is not None else 1
        anchors.update(range(start, start + count))
    return sorted(anchors)
