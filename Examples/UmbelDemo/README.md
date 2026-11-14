# Independent examples

This directory is a pointer to the runnable examples:

- [Native macOS](../UmbelPlay/UmbelPlay.swift): the `umbel-play` SwiftPM executable.
- [iOS / iPadOS](../UmbelPlayiOS/Sources/PlayerViewController.swift): open
  `Examples/UmbelPlayiOS/UmbelPlayiOS.xcodeproj` in Xcode and select a device.

Build the binary dependencies first, as described in the [package README](../../README.md).
From the package root, run the macOS example with a local file or HTTP URL:

```bash
Tools/swift.sh run umbel-play /path/to/video.mp4 60 --pip
```

These examples use the standalone package. For application lifecycle, rendering,
subtitles and release checks, see the [integration guide](../../docs/integration.md).

The iOS example uses `UmbelDisplayDriver` for foreground presentation. Launch
with `-mainstall 0.2` to inject a 200 ms main-thread stall every two seconds;
add `-main-display` to compare the main-thread reference loop. The shared
`UmbelPlaybackChecks` scheme runs real loopback HTTP transport and display
driver tests. See [playback diagnostics](../../docs/playback-diagnostics.md)
for counter definitions, lifecycle boundaries and device acceptance steps.

Both examples print how the sound plays (`audio route:` after loading, and in
`status`): decoded by the engine, or E-AC-3 (JOC) played by the system player.
`--no-object-audio` on macOS and `-no-object-audio` on iOS decode it in the
engine instead. On iOS, `-muted` starts silent, and `-buffer-target <seconds>` sets
how far ahead to read (ten by default).
