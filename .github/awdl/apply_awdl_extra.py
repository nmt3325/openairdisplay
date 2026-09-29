#!/usr/bin/env python3
"""Second wave: surface "AWDL" in the shared perf overlay badge."""
import pathlib
import sys

ROOT = pathlib.Path("/data/work")
fails = []


def edit(rel, old, new, count=1):
    p = ROOT / rel
    s = p.read_text()
    if new in s:
        print("  = already applied: " + rel)
        return
    n = s.count(old)
    if n != count:
        fails.append(rel + ": anchor matched " + str(n) + "x")
        return
    p.write_text(s.replace(old, new, count))
    print("  + " + rel)


# Anchors deliberately stop before a closing quote character.
edit("Shared/PerfOverlay.swift",
     "// Transport badge \u2014 the question \"is this cable or WiFi?",
     "// Transport badge \u2014 the question \"is this the cable, a direct\n"
     "                // AWDL link, or WiFi through a router?")

edit("Shared/PerfOverlay.swift",
     "                    .background(stats.transport == \"USB\" ? Color.green.opacity(0.35)\n"
     "                                : stats.transport == \"WiFi\" ? Color.blue.opacity(0.4)",
     "                    .background(stats.transport == \"USB\" ? Color.green.opacity(0.35)\n"
     "                                : stats.transport == \"AWDL\" ? Color.purple.opacity(0.45)\n"
     "                                : stats.transport == \"WiFi\" ? Color.blue.opacity(0.4)")

edit("Shared/StreamReceiver.swift",
     "    var transport = \"\u2014\"          // USB (loopback via usbmux) or WiFi",
     "    var transport = \"\u2014\"          // USB (usbmux loopback), WiFi (LAN) or AWDL")

if fails:
    print("FAILED: " + "; ".join(fails))
    sys.exit(1)
print("extra edits applied")
