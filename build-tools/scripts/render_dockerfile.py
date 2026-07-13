#!/usr/bin/env python3
import argparse
import pathlib


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    source = pathlib.Path(args.template)
    output = pathlib.Path(args.output)
    if not source.is_file():
        raise SystemExit(f"Dockerfile template does not exist: {source}")
    output.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
