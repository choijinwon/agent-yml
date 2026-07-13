#!/usr/bin/env python3
import argparse
import json
import pathlib
import re


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schema", required=True)
    parser.add_argument("spec")
    args = parser.parse_args()
    schema = json.loads(pathlib.Path(args.schema).read_text(encoding="utf-8"))
    spec = json.loads(pathlib.Path(args.spec).read_text(encoding="utf-8"))
    missing = [key for key in schema["required"] if not spec.get(key)]
    if missing:
        raise SystemExit(f"build spec is missing required values: {missing}")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", spec["parentImageDigest"]):
        raise SystemExit("parentImageDigest is invalid")
    if not spec["runtimeImage"].endswith("@" + spec["parentImageDigest"]):
        raise SystemExit("runtimeImage and parentImageDigest do not match")
    if not re.fullmatch(r"[0-9a-f]{64}", spec["lockHash"]):
        raise SystemExit("lockHash is invalid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
