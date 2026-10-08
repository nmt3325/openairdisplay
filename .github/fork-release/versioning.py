#!/usr/bin/env python3
"""Numeric bundle version for SideStore/LiveContainer; fork tag kept separately."""
import re
import sys

def marketing_version(upstream: str, tag: str) -> str:
    if not re.fullmatch(r"\d+\.\d+\.\d+", upstream):
        raise ValueError("Invalid upstream version: " + upstream)
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)-air(?:\.([2-9]|[1-9]\d+))?", tag)
    if match is None:
        raise ValueError("Invalid fork tag: " + tag)
    major, minor, patch = (int(x) for x in match.group(1,2,3))
    if f"{major}.{minor}.{patch}" != upstream:
        raise ValueError("Fork tag and upstream version differ")
    rev = int(match.group(4) or "0")
    if rev >= 1000:
        raise ValueError("Fork revision 1000+ would collide with upstream patch version")
    return f"{major}.{minor}.{patch * 1000 + rev}"

if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: versioning.py UPSTREAM_VERSION RELEASE_TAG")
    try:
        print(marketing_version(sys.argv[1], sys.argv[2]))
    except ValueError as e:
        raise SystemExit(str(e))
