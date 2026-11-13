#!/usr/bin/env python3
"""Summarize xctrace XML exports for an iOS cold-start profile.

xctrace repeats shared nodes with a `ref` attribute. ElementTree elements
are falsy when they have no children, so this script never treats an
element as a boolean.
"""

import sys
import xml.etree.ElementTree as ET

# Milestones that describe a launch into the timeline. Names come from
# AppSignposts and from Apple's launch instrument.
MILESTONES = (
    "AppInit",
    "EnsureDeviceKey",
    "InitMTLSTransport",
    "RootContentVisible",
    "MainTabsVisible",
    "ApplicationFirstFramePresentation",
    "ContentInitializeRepositoryState",
    "GitInitialize",
    "ManifestDatabaseOpen",
    "TimelineLoadMetadata",
    "TimelineCountItems",
    "TimelineInitialRegionLoad",
    "TimelineMetadataReady",
    "TimelineCollectionViewCreated",
    "TimelineGridFirstLayout",
    "TimelineFirstVisibleThumbnailRendered",
    "TimelineVisibleViewportHydrated",
)

COMMIT_THRESHOLD_NS = 15_000_000


def index(root):
    by_id = {}
    for el in root.iter():
        ident = el.get("id")
        if ident:
            by_id[ident] = el
    return by_id


def resolve(by_id, el):
    if el is None:
        return None
    ref = el.get("ref")
    if ref is None:
        return el
    return by_id.get(ref, el)


def text_of(el):
    if el is None or el.tag == "sentinel":
        return ""
    return el.text or ""


def fields(by_id, row):
    return {child.tag: resolve(by_id, child) for child in row}


def load_rows(path):
    root = ET.parse(path).getroot()
    by_id = index(root)
    return [fields(by_id, row) for row in root.iter("row")]


def signposts(path):
    rows = []
    for field in load_rows(path):
        name = text_of(field.get("signpost-name"))
        when = text_of(field.get("event-time"))
        kind = text_of(field.get("event-type"))
        if not name or not when or not kind:
            continue
        thread = field.get("thread")
        rows.append(
            {
                "t": int(when),
                "name": name,
                "kind": kind,
                "sid": text_of(field.get("os-signpost-identifier")),
                "subsystem": text_of(field.get("subsystem")),
                "category": text_of(field.get("category")),
                "main": thread is not None and "Main Thread" in thread.get("fmt", ""),
            }
        )
    if not rows:
        print("no signpost rows; export the os-signpost table", file=sys.stderr)
        return 1

    rows.sort(key=lambda row: row["t"])
    origin = next((row["t"] for row in rows if row["name"] == "AppInit" and row["kind"] == "Begin"), None)
    if origin is None:
        print("no AppInit begin; this launch did not reach the instrumented init", file=sys.stderr)
        return 1

    def ms(ticks):
        return (ticks - origin) / 1e6

    open_intervals = {}
    intervals = {name: [] for name in MILESTONES}
    commits = []
    decode_count = 0
    decode_ns = 0
    for row in rows:
        key = (row["name"], row["sid"])
        if row["kind"] == "Begin":
            open_intervals.setdefault(key, []).append(row)
        elif row["kind"] == "End":
            begun = open_intervals.get(key)
            # Apple's first-frame interval often arrives as an End only.
            # The Begin was before the trace window.
            if not begun:
                if row["name"] in intervals:
                    intervals[row["name"]].append((row, row))
                continue
            start = begun.pop()
            span = (start, row)
            if row["name"] in intervals:
                intervals[row["name"]].append(span)
            if row["name"] == "TimelineThumbnailDecode":
                decode_count += 1
                decode_ns += row["t"] - start["t"]
            if row["name"] == "Commit" and start["main"] and row["t"] - start["t"] >= COMMIT_THRESHOLD_NS:
                commits.append(span)
        elif row["kind"] == "Event" and row["name"] in intervals:
            intervals[row["name"]].append((row, row))

    print(f"origin AppInit begin")
    for name in MILESTONES:
        spans = intervals[name]
        if not spans:
            print(f"{name}\tMISSING")
            continue
        start, end = spans[0]
        if start is end:
            print(f"{name}\t{ms(start['t']):.0f}")
        else:
            print(
                f"{name}\t{ms(start['t']):.0f}-{ms(end['t']):.0f}"
                f"\t{ms(end['t']) - ms(start['t']):.0f} ms"
            )

    if any(row["name"] == "OnboardingVisible" for row in rows):
        print("WARNING: onboarding was the first screen; this is not a timeline cold start")
    if not intervals["TimelineVisibleViewportHydrated"]:
        print("WARNING: the visible grid never finished painting")

    print("main-thread Commit over 15 ms:")
    if not commits:
        print("  none")
    for start, end in commits:
        print(
            f"  {ms(start['t']):.0f}-{ms(end['t']):.0f}"
            f"\t{ms(end['t']) - ms(start['t']):.0f} ms\t{start['category']}"
        )
    print(
        f"TimelineThumbnailDecode intervals: {decode_count}, "
        f"sum {decode_ns / 1e6:.0f} ms (sum is not wall time)"
    )
    return 0


def path_of(field):
    raw = text_of(field.get("string"))
    if raw:
        return raw
    narrative = field.get("narrative")
    if narrative is None:
        return ""
    return text_of(narrative.find("file-path"))


def dyld(path):
    bundles = []
    top_dlopen = []
    for field in load_rows(path):
        activity = text_of(field.get("dyld-activity"))
        if activity != "dlopen":
            continue
        image = path_of(field)
        start = text_of(field.get("start-time"))
        duration = text_of(field.get("duration"))
        level = text_of(field.get("containment-level"))
        if not start or not duration or not level:
            continue
        record = (int(duration), image)
        if "AccessibilityBundles" in image:
            bundles.append(record)
        if int(level) <= 2:
            top_dlopen.append(record)

    bundle_ms = sum(duration for duration, _ in bundles) / 1e6
    print(f"accessibility bundles: {len(bundles)}, {bundle_ms:.0f} ms of dlopen")
    print("longest top-level dlopens:")
    for duration, image in sorted(top_dlopen, reverse=True)[:8]:
        short = image.split("RuntimeRoot")[-1] or image
        print(f"  {duration / 1e6:7.1f} ms  {short}")
    if bundles:
        print("discard: accessibility bundles were loaded")
        return 2
    print("no accessibility bundles")
    return 0


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("signposts", "dyld"):
        print(
            "usage: summarize_trace.py signposts|dyld <xctrace-export.xml>",
            file=sys.stderr,
        )
        return 2
    command, path = sys.argv[1], sys.argv[2]
    if command == "signposts":
        return signposts(path)
    return dyld(path)


if __name__ == "__main__":
    sys.exit(main())
