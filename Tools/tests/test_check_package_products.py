#!/usr/bin/env python3
"""The package products guard, run on manifests written out by hand."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "Tools" / "check_package_products.py"


def target(name, kind="regular", needs=()):
    return {"name": name, "type": kind, "dependencies": [{"byName": [need, None]} for need in needs]}


def library(name, targets, kind="automatic"):
    return {"name": name, "type": {"library": [kind]}, "targets": list(targets)}


def manifest(products, targets):
    return {"name": "Package", "products": products, "targets": targets}


class PackageProductsGuardTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "tmp", prefix="package-products-test-")
        self.addCleanup(self.temp.cleanup)

    def run_guard(self, document, via_stdin=False):
        text = json.dumps(document)
        if via_stdin:
            return subprocess.run([sys.executable, "-I", str(GUARD), "-"], input=text, capture_output=True, text=True)
        path = Path(self.temp.name) / "manifest.json"
        path.write_text(text)
        return subprocess.run([sys.executable, "-I", str(GUARD), str(path)], capture_output=True, text=True)

    # What an app project can link: the optional modules' targets sit in the
    # one dynamic product, so that nothing else carries a copy of the core.
    def test_modules_inside_the_dynamic_product_pass(self):
        result = self.run_guard(manifest(
            [library("UmbelCore", ["UmbelCore", "UmbelUI", "UmbelSMBSource"], "dynamic")],
            [target("UmbelCore"), target("UmbelUI", needs=["UmbelCore"]),
             target("UmbelSMBSource", needs=["UmbelCore", "LibSMB2", "UmbelSMB2"]),
             target("LibSMB2", "system"), target("UmbelSMB2", "binary")]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    # The defect that only an Xcode app shows: a module as a product of its own
    # puts a second copy of the core beside the dynamic one.
    def test_a_product_over_a_target_the_dynamic_product_carries_fails(self):
        result = self.run_guard(manifest(
            [library("UmbelCore", ["UmbelCore"], "dynamic"), library("UmbelSMBSource", ["UmbelSMBSource"])],
            [target("UmbelCore"), target("UmbelSMBSource", needs=["UmbelCore"])]))
        self.assertEqual(result.returncode, 1)
        self.assertIn("UmbelCore", result.stdout)
        self.assertIn("UmbelSMBSource", result.stdout)

    def test_a_target_reached_through_other_targets_counts(self):
        result = self.run_guard(manifest(
            [library("UmbelCore", ["UmbelCore"], "dynamic"), library("Outer", ["Outer"])],
            [target("UmbelCore"), target("Middle", needs=["UmbelCore"]), target("Outer", needs=["Middle"])]))
        self.assertEqual(result.returncode, 1)
        self.assertIn("UmbelCore", result.stdout)

    def test_two_dynamic_products_over_one_target_fail(self):
        result = self.run_guard(manifest(
            [library("One", ["One"], "dynamic"), library("Two", ["Two"], "dynamic")],
            [target("Shared"), target("One", needs=["Shared"]), target("Two", needs=["Shared"])]))
        self.assertEqual(result.returncode, 1)
        self.assertIn("Shared", result.stdout)

    # Without a dynamic product there is nothing for a copy to be a second one of.
    def test_static_products_may_share_a_target(self):
        result = self.run_guard(manifest(
            [library("One", ["One"]), library("Two", ["Two"])],
            [target("Shared"), target("One", needs=["Shared"]), target("Two", needs=["Shared"])]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    # A prebuilt binary or a system library is not compiled into a product.
    def test_binary_and_system_targets_may_be_shared(self):
        result = self.run_guard(manifest(
            [library("UmbelCore", ["UmbelCore"], "dynamic"), library("Other", ["Other"])],
            [target("UmbelCore", needs=["Prebuilt", "System"]), target("Other", needs=["Prebuilt", "System"]),
             target("Prebuilt", "binary"), target("System", "system")]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    # Another package's products are that package's to carry.
    def test_dependencies_on_other_packages_are_not_followed(self):
        core = target("UmbelCore")
        core["dependencies"].append({"product": ["Thing", "thing", None, None]})
        other = target("Other")
        other["dependencies"].append({"product": ["Thing", "thing", None, None]})
        result = self.run_guard(manifest(
            [library("UmbelCore", ["UmbelCore"], "dynamic"), library("Other", ["Other"])], [core, other]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_manifest_can_come_from_standard_input(self):
        result = self.run_guard(manifest(
            [library("UmbelCore", ["UmbelCore"], "dynamic"), library("Module", ["Module"])],
            [target("UmbelCore"), target("Module", needs=["UmbelCore"])]), via_stdin=True)
        self.assertEqual(result.returncode, 1)

    def test_a_document_that_is_not_a_manifest_fails(self):
        result = self.run_guard({"nothing": "here"})
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
