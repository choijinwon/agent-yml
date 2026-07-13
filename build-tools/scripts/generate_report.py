#!/usr/bin/env python3
import json
import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: generate_report.py INPUT_JSON OUTPUT_JSON", file=sys.stderr)
        return 2
    data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    pathlib.Path(sys.argv[2]).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
