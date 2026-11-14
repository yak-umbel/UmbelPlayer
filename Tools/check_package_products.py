#!/usr/bin/env python3
"""Checks that no library product carries a second copy of a dynamic product's code.

Usage:
  check_package_products.py <manifest.json>   # the output of `swift package dump-package`
  swift package dump-package | check_package_products.py -

An Xcode project cannot link a package target twice, once through a dynamic
product and again through another product that depends on it: it refuses a
target "linked as a static library" while a product of the same name exists,
and where it does not, the app carries two copies of the code, and of every
type in it. SwiftPM's own build does not notice, so only an app in Xcode
shows the defect. The rule, over the targets compiled from source:

  a target that a dynamic library product carries, itself or through the
  targets it depends on, is carried by no other library product.

Products that are static or automatic may share targets with each other; a
prebuilt binary and a system library are not compiled into a product, and are
left out. Other packages' products are theirs to carry.

Exit status: 0 passes, 1 breaks the rule, 2 is not a manifest.
"""
import json
import sys


def fail_not_a_manifest(why):
    print(f"✗ package products check: not a package manifest: {why}", file=sys.stderr)
    sys.exit(2)


def load(source):
    try:
        document = json.load(sys.stdin) if source == "-" else json.load(open(source))
    except (OSError, ValueError) as error:
        fail_not_a_manifest(str(error))
    if not isinstance(document, dict) or not isinstance(document.get("products"), list) \
            or not isinstance(document.get("targets"), list):
        fail_not_a_manifest("it has no products and targets")
    return document


def needs_of(target):
    """Names of the package's own targets this one depends on."""
    names = []
    for dependency in target.get("dependencies", []):
        for kind in ("target", "byName"):
            if kind in dependency:
                names.append(dependency[kind][0])
    return names


def carried_by(product, targets):
    """What the product compiles from source: its targets and theirs, to the end."""
    seen = set()
    pending = list(product["targets"])
    while pending:
        name = pending.pop()
        found = targets.get(name)
        # A name that is no target of the package is another package's product.
        if found is None or name in seen or found.get("type") != "regular":
            continue
        seen.add(name)
        pending.extend(needs_of(found))
    return seen


def breaches(document):
    """(dynamic product, other product, shared targets) for each pair that shares any."""
    targets = {target["name"]: target for target in document["targets"]}
    products = [product for product in document["products"] if "library" in product.get("type", {})]
    carried = {product["name"]: carried_by(product, targets) for product in products}
    found = []
    for product in products:
        if "dynamic" not in product["type"]["library"]:
            continue
        for other in products:
            if other is product:
                continue
            shared = sorted(carried[product["name"]] & carried[other["name"]])
            if shared:
                found.append((product["name"], other["name"], shared))
    return found


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    found = breaches(load(sys.argv[1]))
    for dynamic, other, shared in found:
        print(f"✗ the dynamic product {dynamic} and the product {other} both carry {', '.join(shared)}: "
              f"an app in Xcode would link them twice. Put what {other} holds into {dynamic}.")
    if found:
        return 1
    print("✓ package products check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
