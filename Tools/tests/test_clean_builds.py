#!/usr/bin/env python3
"""Exercise deletion boundaries with disposable repositories and real files."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools/clean_builds.py"


class CleanBuildsTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.exists(), "the cleanup command has not been implemented")
        spec = importlib.util.spec_from_file_location("clean_builds", SCRIPT)
        self.cleaner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.cleaner)
        (ROOT / "tmp").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "tmp", prefix="clean-builds-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def put(self, name, data="keep"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)
        return path

    def test_preview_lists_cache_without_deleting_it_or_other_files(self):
        cache = self.put("tmp/swift-build/object.o")
        kept = [self.put(name) for name in (
            "Sources/Player.swift", "tmp/experiment/input.patch", "videos/sample.mov",
            "Binaries/UmbelFFmpeg.xcframework/binary", "tmp/releases/v1/app.xcarchive/symbols",
        )]
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(self.cleaner.main(["--older-than-days", "0"], root=self.root), 0)
        self.assertIn("tmp/swift-build", output.getvalue())
        self.assertTrue(all(p.exists() for p in [cache, *kept]))

    def test_deletion_removes_only_eligible_cache(self):
        cache = self.put("tmp/swift-build/object.o")
        report = self.put("tmp/experiment/results.md")
        with patch.object(self.cleaner, "active_builds", return_value=[]):
            self.assertEqual(self.cleaner.main(["--delete", "--older-than-days", "0"], root=self.root), 0)
        self.assertFalse(cache.exists())
        self.assertEqual(report.read_text(), "keep")

    def test_recent_file_prevents_deleting_old_directory(self):
        cache = self.put("tmp/swift-build/object.o")
        old = time.time() - 10 * 86400
        os.utime(cache.parent, (old, old))
        with patch.object(self.cleaner, "active_builds", return_value=[]):
            self.assertEqual(self.cleaner.main(["--delete"], root=self.root), 0)
            self.assertTrue(cache.exists())
            os.utime(cache, (old, old))
            self.assertEqual(self.cleaner.main(["--delete"], root=self.root), 0)
        self.assertFalse(cache.exists())

    def test_symlinked_candidate_and_parent_are_never_followed(self):
        outside = self.put("retained/valuable.txt")
        (self.root / "tmp").mkdir()
        (self.root / "tmp/swift-build").symlink_to(outside.parent, target_is_directory=True)
        with patch.object(self.cleaner, "active_builds", return_value=[]):
            self.cleaner.main(["--delete", "--older-than-days", "0"], root=self.root)
        self.assertEqual(outside.read_text(), "keep")
        self.assertTrue((self.root / "tmp/swift-build").is_symlink())
        (self.root / "tmp/swift-build").unlink()
        (self.root / "tmp").rmdir()
        (self.root / "tmp").symlink_to(outside.parent, target_is_directory=True)
        self.put("retained/swift-build/object.o")
        with patch.object(self.cleaner, "active_builds", return_value=[]):
            self.cleaner.main(["--delete", "--older-than-days", "0"], root=self.root)
        self.assertTrue((outside.parent / "swift-build/object.o").exists())

    def test_link_inside_cache_does_not_delete_its_target(self):
        outside = self.put("retained/valuable.txt")
        self.put("tmp/swift-build/object.o")
        (self.root / "tmp/swift-build/link").symlink_to(outside.parent, target_is_directory=True)
        with patch.object(self.cleaner, "active_builds", return_value=[]):
            self.cleaner.main(["--delete", "--older-than-days", "0"], root=self.root)
        self.assertEqual(outside.read_text(), "keep")
        self.assertFalse((self.root / "tmp/swift-build").exists())

    def test_tracked_content_blocks_deletion(self):
        tracked = self.put("tmp/swift-build/important.patch")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        with patch.object(self.cleaner, "active_builds", return_value=[]):
            self.assertNotEqual(self.cleaner.main(["--delete", "--older-than-days", "0"], root=self.root), 0)
        self.assertTrue(tracked.exists())

    def test_release_archive_blocks_the_entire_deletion_selection(self):
        cache = self.put("tmp/swift-build/object.o")
        archive = self.put("tmp/xcode-derived/release.xcarchive/symbols.dSYM/data")
        with patch.object(self.cleaner, "active_builds", return_value=[]):
            self.assertNotEqual(self.cleaner.main(["--delete", "--older-than-days", "0"], root=self.root), 0)
        self.assertTrue(cache.exists())
        self.assertTrue(archive.exists())

    def test_active_build_or_unavailable_process_list_blocks_deletion(self):
        cache = self.put("tmp/swift-build/object.o")
        with patch.object(self.cleaner, "active_builds", return_value=["123 swift-build"]):
            self.assertNotEqual(self.cleaner.main(["--delete", "--older-than-days", "0"], root=self.root), 0)
        with patch.object(self.cleaner, "active_builds", side_effect=RuntimeError("process list unavailable")):
            self.assertNotEqual(self.cleaner.main(["--delete", "--older-than-days", "0"], root=self.root), 0)
        self.assertTrue(cache.exists())

    def test_budget_warning_also_counts_recent_caches(self):
        self.put("tmp/swift-build/object.o", "x" * 8192)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(self.cleaner.main(["--check", "--budget-gib", "0.000001"], root=self.root), 0)
        self.assertIn("WARNING", output.getvalue())
        self.assertTrue((self.root / "tmp/swift-build/object.o").exists())


if __name__ == "__main__":
    unittest.main()
