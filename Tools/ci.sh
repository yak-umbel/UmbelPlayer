#!/bin/bash
# The one definition of CI: the same checks run locally and on the CI runner.
#
# Any failing step fails the whole; steps go from fast to slow, so problems
# show early.
#
# usage: Tools/ci.sh [all|stable|realtime]
#   all       every check and every test (the default; what a developer runs)
#   stable    everything but the real-time group of tests (Tools/realtime_tests.sh)
#   realtime  only that group, on what an earlier run built
# The CI runner runs stable, then realtime as a step whose result is shown but
# does not decide: its virtual machine cannot give a verdict on tests that read
# a real clock. A developer machine has no such excuse, so it runs all.
#
# swift build and swift test need the FFmpeg and libass xcframeworks under
# Binaries/, which are not in git (see .gitignore). A fresh checkout runs
# Tools/BuildFFmpeg/build.sh and Tools/BuildLibass/build.sh first.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
MODE="${1:-all}"
case "$MODE" in
  all|stable|realtime) ;;
  *) echo "usage: $0 [all|stable|realtime]" >&2; exit 2 ;;
esac
# shellcheck source=realtime_tests.sh
source "$ROOT/Tools/realtime_tests.sh"
mkdir -p "$ROOT/tmp/process"
export TMPDIR="$ROOT/tmp/process/"
FAILED=()

run_step() {
  local label="$1"; shift
  echo ""
  echo "══════ $label ══════"
  if "$@"; then
    echo "✓ $label"
  else
    echo "✗ $label"
    FAILED+=("$label")
  fi
}

conclude() {
  echo ""
  if [ "${#FAILED[@]}" -eq 0 ]; then
    echo "══════ all passed ══════"
    exit 0
  fi
  echo "══════ failed ══════"
  printf '  ✗ %s\n' "${FAILED[@]}"
  exit 1
}

# Only the real-time group: the products of the run before are in place, and
# swift test builds what is missing.
if [ "$MODE" = realtime ]; then
  run_step "real-time tests" Tools/swift.sh test --filter "$UMBEL_REALTIME_TESTS"
  conclude
fi

# The name list lives outside the repository; where there is none, as on a
# CI runner, this check says so and passes.
run_step "name guard" python3 Tools/check_names.py tree --if-available
run_step "name guard tests" Tools/tests/test_check_names.sh
run_step "independence guard" Tools/check_independence.sh
run_step "license guard tests" Tools/tests/test_verify_ffmpeg_license.sh
run_step "libass license guard tests" Tools/tests/test_verify_libass_license.sh
run_step "network libraries guard tests" Tools/tests/test_verify_network_libraries.sh
run_step "framework packaging tests" Tools/tests/test_framework.sh
run_step "link tool tests" Tools/tests/test_link_dylib.sh
run_step "binaries check tests" Tools/tests/test_check_binaries.sh
run_step "binaries check" Tools/check_binaries.sh --all Binaries
run_step "archive symbols check tests" Tools/tests/test_check_archive_symbols.sh
run_step "FFmpeg license check" Tools/verify_ffmpeg_license.sh --binaries Binaries
run_step "privacy manifest tests" Tools/tests/test_check_privacy_manifest.sh
run_step "privacy manifest check" Tools/check_privacy_manifest.sh --all
run_step "packaging tests" Tools/tests/test_package_binaries.sh
# The binaries themselves too: when CI restores them from cache, the check
# made while building them did not run.
run_step "libass license check" Tools/verify_libass_license.sh --binaries Binaries
# Passes where none of the optional network libraries has been built.
run_step "network libraries check" Tools/verify_network_libraries.sh --binaries Binaries
run_step "structure guard" Tools/check_structure.sh
run_step "structure guard tests" Tools/tests/test_check_structure.sh
# An app in Xcode cannot link a module that is a product of its own beside the
# dynamic UmbelCore; swift build does not notice, so the manifest is checked.
check_package_products() {
  local manifest="$ROOT/tmp/process/package-manifest.json"
  Tools/swift.sh package dump-package > "$manifest" && python3 -I Tools/check_package_products.py "$manifest"
}
run_step "package products guard tests" python3 -B Tools/tests/test_check_package_products.py
run_step "package products check" check_package_products
run_step "cache cleanup tests" python3 -B Tools/tests/test_clean_builds.py
run_step "build storage tests" python3 -B Tools/tests/test_build_storage.py
run_step "display layer actor check" Tools/tests/test_display_layer_access.sh
run_step "real-time group check tests" Tools/tests/test_check_realtime_tests.sh
run_step "build" Tools/swift.sh build
run_step "iOS 15 deployment build" Tools/check_ios_deployment.sh
# The check lists the tests, which builds them; the tests step reuses that.
run_step "real-time group check" Tools/check_realtime_tests.sh
if [ "$MODE" = stable ]; then
  run_step "tests (all but the real-time group)" Tools/swift.sh test --skip "$UMBEL_REALTIME_TESTS"
else
  run_step "tests" Tools/swift.sh test
fi

conclude
