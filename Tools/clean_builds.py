#!/usr/bin/env python3
"""Preview or remove the project's dedicated, reproducible build caches."""
import argparse
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


CACHE_PATHS = (
    "tmp/swift-build", "tmp/swiftpm-cache", "tmp/xcode-derived",
    "tmp/ffmpeg-build", "tmp/libass-build", "tmp/network-build", "tmp/ios-smoke",
    "Tools/BuildFFmpeg/build", "Tools/BuildLibass/build",
)
BUILD_PROCESSES = {
    "swift", "swift-build", "swift-test", "swift-run", "swift-package",
    "swift-frontend", "swift-driver", "swiftc", "xcodebuild", "xctest",
    "clang", "clang++", "cc", "c++", "ld", "make", "gmake", "ninja", "cmake",
}


def real_directory(root, path):
    """Reject links in every path component, including the cache's parent."""
    relative = path.relative_to(root)
    if not relative.parts:
        return False
    current = root
    for part in relative.parts:
        if part in (".", ".."):
            return False
        current = current / part
        if current.is_symlink() or not current.is_dir():
            return False
    return True


def tree_info(path):
    """Allocated bytes, latest modification, and presence of a release archive."""
    size, newest, archive = 0, path.stat().st_mtime, False
    seen = set()
    for base, directories, files in os.walk(path, followlinks=False, onerror=raise_error):
        archive |= Path(base).suffix == ".xcarchive"
        for name in directories + files:
            entry = Path(base) / name
            stat = entry.lstat()
            newest = max(newest, stat.st_mtime)
            key = (stat.st_dev, stat.st_ino)
            if key not in seen:
                size += stat.st_blocks * 512
                seen.add(key)
        directories[:] = [name for name in directories if not (Path(base) / name).is_symlink()]
    return size, newest, archive


def raise_error(error):
    raise error


def tracked_files(root):
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"], check=True, capture_output=True)
    return [os.fsdecode(name) for name in result.stdout.split(b"\0") if name]


def active_builds():
    result = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("Cannot inspect running builds; no caches were deleted. " + result.stderr.strip())
    return [line.strip() for line in result.stdout.splitlines()
            if len(line.split(None, 1)) == 2
            and Path(line.split(None, 1)[1]).name in BUILD_PROCESSES]


def validate_paths(root, paths):
    tracked = tracked_files(root)
    for path in paths:
        relative = path.relative_to(root).as_posix()
        permitted = relative.startswith(("tmp/", ".build/")) or relative in CACHE_PATHS
        if not permitted or not real_directory(root, path):
            raise RuntimeError(f"Refusing a path outside the build directories or through a link: {path}")
        if any(name == relative or name.startswith(relative + "/") for name in tracked):
            raise RuntimeError(f"Refusing a directory with Git-tracked files: {relative}")
        if tree_info(path)[2]:
            raise RuntimeError(f"Refusing a directory containing a release archive: {relative}")


def delete_paths(root, paths):
    """Validate the entire selection before deleting any of it."""
    validate_paths(root, paths)
    if not shutil.rmtree.avoids_symlink_attacks:
        raise RuntimeError("This Python does not provide symlink-resistant directory deletion")
    for path in paths:
        running = active_builds()
        if running:
            raise RuntimeError("Stop the running build/test processes before cleaning:\n" + "\n".join(running))
        validate_paths(root, [path])
        shutil.rmtree(path)
        print(f"Removed {path.relative_to(root)}")


def nonnegative(value):
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise argparse.ArgumentTypeError("must be a finite, nonnegative number")
    return number


def main(argv=None, *, root=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--delete", action="store_true", help="delete the listed eligible caches")
    mode.add_argument("--check", action="store_true", help="only warn when the cache budget is exceeded")
    parser.add_argument("--older-than-days", type=nonnegative, default=7,
                        help="require no modifications for this many days (default: 7; 0 includes recent caches)")
    parser.add_argument("--budget-gib", type=nonnegative, default=10,
                        help="warn above this total cache size (default: 10 GiB)")
    args = parser.parse_args(argv)
    root = Path(root or Path(__file__).resolve().parent.parent).resolve()
    try:
        entries = []
        cutoff = time.time() - args.older_than_days * 86400
        for relative in CACHE_PATHS:
            path = root / relative
            if real_directory(root, path):
                size, newest, _ = tree_info(path)
                entries.append((path, size, newest <= cutoff))
        total = sum(size for _, size, _ in entries)
        if total > args.budget_gib * 1024**3:
            print(f"WARNING: build caches use {total / 1024**3:.2f} GiB "
                  f"(budget {args.budget_gib:g} GiB). Run python3 Tools/clean_builds.py to review.")
        if args.check:
            return 0
        for path, size, eligible in entries:
            print(f"{size / 1024**3:7.2f} GiB  {'eligible' if eligible else 'recent  '}  {path.relative_to(root)}")
        selected = [path for path, _, eligible in entries if eligible]
        estimate = sum(size for _, size, eligible in entries if eligible)
        print(f"Eligible: {estimate / 1024**3:.2f} GiB in {len(selected)} directories. "
              "APFS shared blocks and snapshots can reduce actual reclaimed space.")
        if args.delete:
            delete_paths(root, selected)
        else:
            print("Preview only. Pass --delete to remove eligible caches; source and release directories are excluded.")
        return 0
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
