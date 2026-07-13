#!/usr/bin/env python3
import pathlib
import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_lock.py LOCK_FILE", file=sys.stderr)
        return 2
    path = pathlib.Path(sys.argv[1])
    if not path.is_file() or path.stat().st_size == 0:
        print(f"lock file is missing or empty: {path}", file=sys.stderr)
        return 1
    invalid = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        requirement = line.split(" ; ", 1)[0]
        if requirement.startswith(("-", "git+", "http://", "https://")) or "==" not in requirement:
            invalid.append(number)
    if invalid:
        print(f"lock entries must use exact == pins; invalid lines: {invalid}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
