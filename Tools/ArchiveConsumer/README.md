# Release archive symbols

Run `Tools/archive_release_symbols.sh` from the package root on a Mac with Xcode
and the iOS device SDK installed. It creates an unsigned standalone consumer in
a directory under `tmp/releases/`, archives that consumer for iOS devices and macOS using
the Release configuration, then runs `Tools/check_archive_symbols.sh` on each
`.xcarchive`. The command prints the retained output directory; pass an empty
directory as its argument to choose one. No device, signing identity, or
provisioning profile is needed.

The command shares intermediate data between its two platform builds in an
invocation-specific directory under `tmp/xcode-derived/`. An exit trap removes
that directory on success or failure; archives, dSYMs, and logs remain in the
output directory. Abrupt termination that prevents exit traps from running
may leave a cache; `python3 Tools/clean_builds.py` previews old caches for cleanup.

The fixture's Release configuration and archive command explicitly set
`DEBUG_INFORMATION_FORMAT=dwarf-with-dsym`, including for the Swift package
product. A consuming application's Release archive must also produce dSYMs
for its package products. This command validates the artifacts made with this
fixture and these settings; it does not establish the symbol settings of a
different application.

The check requires all four embedded dynamic frameworks (`UmbelCore`,
`UmbelFFmpeg`, `UmbelASS`, and `UmbelFriBidi`) and a dSYM for every embedded
framework. Each dSYM must have the same architecture/UUID pairs as its
framework binary, verified DWARF with a function record, and nonempty
`__debug_info` for every architecture. The
prebuilt slice check, `Tools/check_binaries.sh --all Binaries`, remains a
separate prerequisite; only an archive proves what the consumer actually
embeds. Archive failures leave the Xcode log alongside the archive output.

`Tools/tests/test_check_archive_symbols.sh` runs small Mach-O fixtures for
matching, missing, mismatched, empty, functionless, and corrupt debug symbols.
CI runs these fast
checker tests; a release run also needs the full archive command above.
