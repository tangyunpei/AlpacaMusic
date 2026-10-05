#!/usr/bin/env python3
"""Prepare version metadata before signing; publish it only with a verified app.

The caller holds the build-app.sh process lock for both operations. This helper
never signs or modifies an app after signing and uses only the Python stdlib.
"""

import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import sys


VERSION = "CFBundleShortVersionString"
BUILD = "CFBundleVersion"


def replace_versions(data, version, build):
    # Keep the source's XML formatting and every unrelated byte intact. The
    # signed app's plist may contain transient signing/MusicKit overrides.
    text = data.decode("utf-8")
    for key, value in ((VERSION, version), (BUILD, build)):
        pattern = rf"(<key>\s*{key}\s*</key>\s*<string>)[^<]*(</string>)"
        text, count = re.subn(pattern, lambda match: match[1] + value + match[2], text)
        if count != 1:
            raise ValueError(f"Info.plist must contain exactly one XML string for {key}.")
    result = text.encode("utf-8")
    parsed = plistlib.loads(result)
    if parsed[VERSION] != version or parsed[BUILD] != build:
        raise ValueError("The prepared version metadata did not round-trip.")
    return result


def prepare(root: Path, stage: Path, configuration: str):
    if configuration not in ("release", "debug"):
        raise ValueError("CONFIGURATION must be release or debug.")
    source = root / "Info.plist"
    original = source.read_bytes()
    info = plistlib.loads(original)
    version, build = info.get(VERSION), info.get(BUILD)
    if not isinstance(version, str) or not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError("CFBundleShortVersionString must be three numbers, for example 0.1.0.")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("CFBundleVersion must be a positive integer, for example 1.")
    if configuration == "release":
        major, minor, patch = version.split(".")
        version = f"{major}.{minor}.{int(patch) + 1}"
        build = str(int(build) + 1)
    next_info = replace_versions(original, version, build)
    stage.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, stage / "source-info.plist")
    # Use the captured bytes even if an editor writes the source during copy2.
    (stage / "source-info.plist").write_bytes(original)
    shutil.copy2(stage / "source-info.plist", stage / "next-info.plist")
    (stage / "next-info.plist").write_bytes(next_info)
    app_info = stage / "AlpacaMusic.app/Contents/Info.plist"
    app_info.parent.mkdir(parents=True, exist_ok=True)
    app_info.write_bytes(next_info)
    state = {"configuration": configuration, "version": version, "build": build}
    (stage / "version-state.json").write_text(json.dumps(state))
    print(f"Preparing {configuration}: {version} (build {build})")


def publish(root: Path, stage: Path):
    source = root / "Info.plist"
    original = (stage / "source-info.plist").read_bytes()
    if source.read_bytes() != original:
        raise ValueError("Info.plist changed during the build; keeping your edits and the previous app. Run the build again.")
    state = json.loads((stage / "version-state.json").read_text())
    app = stage / "AlpacaMusic.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    next_info = plistlib.loads((stage / "next-info.plist").read_bytes())
    for key, field in ((VERSION, "version"), (BUILD, "build")):
        if info.get(key) != state[field] or next_info.get(key) != state[field]:
            raise ValueError("The signed app and prepared source versions do not match.")
    installed = root / "build/AlpacaMusic.app"
    previous = stage / "previous.app"
    marker = stage / "install-in-progress"
    if previous.exists() or marker.exists():
        raise ValueError("An unfinished publication already exists in this staging directory.")
    marker.write_text("Preserve this directory: app/source publication or rollback may be incomplete.\n")
    try:
        if installed.exists() or installed.is_symlink():
            os.replace(installed, previous)
        os.replace(app, installed)
        if state["configuration"] == "release":
            if source.read_bytes() != original:
                raise ValueError("Info.plist changed during publication; keeping your edits and restoring the previous app.")
            os.replace(stage / "next-info.plist", source)
        marker.unlink()
    except BaseException:
        # Do not let a second interrupt terminate recovery halfway through.
        old_handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
        try:
            # Inspect completed renames instead of flags assigned after them: a
            # signal may arrive between os.replace returning and the next line.
            if state["configuration"] == "release" and not (stage / "next-info.plist").exists():
                os.replace(stage / "source-info.plist", source)
            if not app.exists() and installed.exists():
                os.replace(installed, app)
            if previous.exists() or previous.is_symlink():
                os.replace(previous, installed)
            marker.unlink(missing_ok=True)
        finally:
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
        raise
    print(f"Built {state['version']} (build {state['build']})")


def interrupted(signum, frame):
    raise InterruptedError(f"Build publication interrupted by signal {signum}.")


def main():
    signal.signal(signal.SIGTERM, interrupted)
    if len(sys.argv) == 5 and sys.argv[1] == "prepare":
        prepare(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
    elif len(sys.argv) == 4 and sys.argv[1] == "publish":
        publish(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        raise ValueError("Usage: build-version.py prepare ROOT STAGE CONFIGURATION | publish ROOT STAGE")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        print(f"AlpacaMusic: {error}", file=sys.stderr)
        sys.exit(1)
