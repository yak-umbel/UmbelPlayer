#!/usr/bin/env python3
"""Run the build entry points with toolchain doubles, without compiling archives."""
import ast
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BuildStorageTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "tmp", prefix="build-storage-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Tools").mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.root / "tmp/process").mkdir(parents=True)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        STORAGE_TEST_ROOT=str(self.root), TMPDIR=str(self.root / "tmp/process"))

    def executable(self, path, contents):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        path.chmod(0o755)

    def copy_tool(self, name):
        source = ROOT / "Tools" / name
        self.assertTrue(source.exists(), f"missing build entry point: {name}")
        shutil.copy2(source, self.root / "Tools" / name)

    def run_tool(self, name, *args, **env):
        return subprocess.run(["bash", str(self.root / "Tools" / name), *args],
                              env=dict(self.env, **env), capture_output=True, text=True)

    def prepare_swift(self):
        self.copy_tool("swift.sh")
        self.copy_tool("clean_builds.py")
        self.executable(self.bin / "swift", """#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
root = Path(os.environ['STORAGE_TEST_ROOT'])
if sys.argv[1] == 'package' and 'reset' in sys.argv:
    shutil.rmtree(sys.argv[sys.argv.index('--scratch-path') + 1])
with (root / 'calls.jsonl').open('a') as out:
    out.write(json.dumps({'args': sys.argv[1:], 'temp': os.environ['TMPDIR']}) + '\\n')
print('tool-output')
sys.exit(int(os.environ.get('STORAGE_TEST_EXIT', '0')))
""")

    def test_swift_reuses_project_cache_preserves_arguments_and_exit_code(self):
        self.prepare_swift()
        first = self.run_tool("swift.sh", "build", "--product", "name with spaces")
        second = self.run_tool("swift.sh", "test", STORAGE_TEST_EXIT="42")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout.strip(), "tool-output")
        self.assertEqual(second.returncode, 42, second.stderr)
        calls = [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]
        for call in calls:
            args = call["args"]
            self.assertEqual(args[args.index("--scratch-path") + 1], str(self.root / "tmp/swift-build"))
            self.assertEqual(args[args.index("--cache-path") + 1], str(self.root / "tmp/swiftpm-cache"))
            self.assertTrue(Path(call["temp"]).is_relative_to(self.root / "tmp"))
        self.assertEqual(calls[0]["args"][-2:], ["--product", "name with spaces"])

    def test_package_reset_does_not_turn_the_cache_directory_into_a_file(self):
        self.prepare_swift()
        reset = self.run_tool("swift.sh", "package", "reset")
        self.assertEqual(reset.returncode, 0, reset.stderr)
        self.assertTrue((self.root / "tmp/swift-build").is_dir())
        build = self.run_tool("swift.sh", "build")
        self.assertEqual(build.returncode, 0, build.stderr)

    def test_libass_compiler_flags_hide_source_and_build_directory_paths(self):
        # Invoke the actual cross-file generator, without downloading or
        # compiling dependencies, then compile one object with its flags.
        for name in ("framework.sh", "link_dylib.sh", "clean_builds.py"):
            self.copy_tool(name)
        here = self.root / "Tools/BuildLibass"
        here.mkdir()
        script = (ROOT / "Tools/BuildLibass/build.sh").read_text()
        (here / "build.sh").write_text(script.replace('\nmain "$@"\n', '\nwrite_cross_file "$@"\n'))
        work = self.root / "tmp/libass-build/work"
        work.mkdir(parents=True)
        source = here / "source.c"
        source.write_text("int storage_probe(void) { return 1; }\n")
        cross = work / "cross.txt"
        result = self.run_tool("BuildLibass/build.sh", str(cross), "macosx", "arm64", "-mmacosx-version-min=12.0", "darwin")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        flags = ast.literal_eval(next(line.split("=", 1)[1].strip()
                                     for line in cross.read_text().splitlines() if line.startswith("c_args =")))
        subprocess.run(["xcrun", "clang", *flags, "-c", str(source), "-o", "probe.o"], cwd=work, check=True)
        dwarf = subprocess.check_output(["xcrun", "dwarfdump", "--debug-info", "probe.o"], cwd=work, text=True)
        paths = "\n".join(line for line in dwarf.splitlines() if "DW_AT_comp_dir" in line or "DW_AT_name" in line)
        self.assertIn("/umbel/", paths)
        self.assertNotIn(str(self.root), paths)

    def prepare_archiver(self):
        self.copy_tool("archive_release_symbols.sh")
        self.copy_tool("clean_builds.py")
        (self.root / "Tools/ArchiveConsumer").mkdir()
        for name in ("UmbelFFmpeg", "UmbelASS", "UmbelFriBidi"):
            (self.root / f"Binaries/{name}.xcframework").mkdir(parents=True)
        self.executable(self.bin / "xcrun", "#!/bin/sh\nexit 0\n")
        self.executable(self.root / "Tools/check_archive_symbols.sh", "#!/bin/sh\nexit 0\n")
        self.executable(self.bin / "xcodebuild", """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
root = Path(os.environ['STORAGE_TEST_ROOT'])
derived = Path(args[args.index('-derivedDataPath') + 1])
archive = Path(args[args.index('-archivePath') + 1])
derived.mkdir(parents=True, exist_ok=True)
(derived / 'large-object.o').write_text('temporary')
with (root / 'archives.jsonl').open('a') as out:
    out.write(json.dumps({'derived': str(derived), 'archive': str(archive)}) + '\\n')
for name in ('UmbelCore', 'UmbelFFmpeg', 'UmbelASS', 'UmbelFriBidi'):
    (archive / f'Products/Applications/Test.app/Frameworks/{name}.framework').mkdir(parents=True)
symbols = archive / 'dSYMs/evidence'
symbols.parent.mkdir(parents=True)
symbols.write_text('retain symbols')
print('build log')
sys.exit(int(os.environ.get('STORAGE_TEST_EXIT', '0')))
""")

    def check_archive_run(self, failure=False):
        self.prepare_archiver()
        result = self.run_tool("archive_release_symbols.sh", STORAGE_TEST_EXIT="1" if failure else "0")
        self.assertEqual(result.returncode, 1 if failure else 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in (self.root / "archives.jsonl").read_text().splitlines()]
        self.assertEqual(len(calls), 1 if failure else 2)
        for call in calls:
            archive, derived = Path(call["archive"]), Path(call["derived"])
            self.assertTrue(archive.is_relative_to(self.root / "tmp/releases"))
            self.assertTrue(derived.is_relative_to(self.root / "tmp/xcode-derived"))
            self.assertFalse(derived.exists(), "intermediate data must not outlive the archive command")
            self.assertEqual((archive / "dSYMs/evidence").read_text(), "retain symbols")
            self.assertIn("build log", (archive.parent / (archive.stem + ".log")).read_text())

    def test_archive_success_retains_symbols_and_logs_but_removes_intermediates(self):
        self.check_archive_run()

    def test_archive_failure_retains_evidence_but_removes_intermediates(self):
        self.check_archive_run(failure=True)


if __name__ == "__main__":
    unittest.main()
