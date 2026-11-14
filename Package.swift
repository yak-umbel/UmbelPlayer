// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The optional network modules: each is declared only where the library
// behind it has been built (Tools/BuildNetwork/build.sh). A checkout that has
// not built one builds the rest as before. The module's target goes into the
// dynamic UmbelCore product, not into a product of its own: as one, Xcode
// would carry the core a second time inside it and cannot give the core its
// own library under the product's name (Tools/check_package_products.py
// checks it). So an app carries the modules whose libraries were built where
// it was built, and `import Umbel<Name>Source` is as before.
let optionalModules: (sourceTargets: [String], targets: [Target]) = {
  let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  func isBuilt(_ xcframework: String) -> Bool {
    FileManager.default.fileExists(atPath: here.appendingPathComponent("Binaries/\(xcframework).xcframework").path)
  }
  var sourceTargets: [String] = []
  var targets: [Target] = []
  if isBuilt("UmbelSRT") {
    sourceTargets.append("UmbelSRTSource")
    targets += [
      // SRT, with OpenSSL linked into it, as one dynamic library of its own.
      .binaryTarget(name: "UmbelSRT", path: "Binaries/UmbelSRT.xcframework"),
      .systemLibrary(name: "LibSRT"),
      .target(
        name: "UmbelSRTSource",
        dependencies: ["UmbelCore", "LibSRT", "UmbelSRT"],
        resources: [.copy("Notices/Texts")]
      ),
      .testTarget(
        name: "UmbelSRTSourceTests",
        dependencies: ["UmbelSRTSource", "UmbelCore", "LibSRT", "UmbelSRT"]
      ),
    ]
  }
  if isBuilt("UmbelSSH2") {
    sourceTargets.append("UmbelSFTPSource")
    targets += [
      // libssh2, with OpenSSL linked into it, as one dynamic library of its own.
      .binaryTarget(name: "UmbelSSH2", path: "Binaries/UmbelSSH2.xcframework"),
      .systemLibrary(name: "LibSSH2"),
      .target(
        name: "UmbelSFTPSource",
        dependencies: ["UmbelCore", "LibSSH2", "UmbelSSH2"],
        resources: [.copy("Notices/Texts")]
      ),
      .testTarget(
        name: "UmbelSFTPSourceTests",
        dependencies: ["UmbelSFTPSource", "UmbelCore", "LibSSH2", "UmbelSSH2"]
      ),
    ]
  }
  if isBuilt("UmbelRIST") {
    sourceTargets.append("UmbelRISTSource")
    targets += [
      // librist, with the AES it carries itself, as one dynamic library of its own.
      .binaryTarget(name: "UmbelRIST", path: "Binaries/UmbelRIST.xcframework"),
      .systemLibrary(name: "LibRIST"),
      .target(
        name: "UmbelRISTSource",
        dependencies: ["UmbelCore", "LibRIST", "UmbelRIST"],
        resources: [.copy("Notices/Texts")]
      ),
      .testTarget(
        name: "UmbelRISTSourceTests",
        dependencies: ["UmbelRISTSource", "UmbelCore", "LibRIST", "UmbelRIST"]
      ),
    ]
  }
  if isBuilt("UmbelSMB2") {
    sourceTargets.append("UmbelSMBSource")
    targets += [
      // libsmb2 (LGPL), alone in a dynamic library of its own, which an app can replace.
      .binaryTarget(name: "UmbelSMB2", path: "Binaries/UmbelSMB2.xcframework"),
      .systemLibrary(name: "LibSMB2"),
      .target(
        name: "UmbelSMBSource",
        dependencies: ["UmbelCore", "LibSMB2", "UmbelSMB2"],
        resources: [.copy("Notices/Texts")]
      ),
      .testTarget(
        name: "UmbelSMBSourceTests",
        dependencies: ["UmbelSMBSource", "UmbelCore", "LibSMB2", "UmbelSMB2"]
      ),
    ]
  }
  if isBuilt("UmbelNFS") {
    sourceTargets.append("UmbelNFSSource")
    targets += [
      // libnfs (LGPL), alone in a dynamic library of its own, which an app can replace.
      .binaryTarget(name: "UmbelNFS", path: "Binaries/UmbelNFS.xcframework"),
      .systemLibrary(name: "LibNFS"),
      .target(
        name: "UmbelNFSSource",
        dependencies: ["UmbelCore", "LibNFS", "UmbelNFS"],
        resources: [.copy("Notices/Texts")]
      ),
      .testTarget(
        name: "UmbelNFSSourceTests",
        dependencies: ["UmbelNFSSource", "UmbelCore", "LibNFS", "UmbelNFS"]
      ),
    ]
  }
  return (sourceTargets, targets)
}()

// FFmpeg, libass and FriBidi come as prebuilt xcframeworks under names of
// the project's own, so that an app carrying another copy of any of them —
// under the upstream names — builds and runs with both.
let package = Package(
  name: "UmbelPlayer",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
    .macCatalyst(.v15),
    .tvOS(.v15),
    .visionOS(.v1),
  ],
  products: [
    // The playback core, and the default player interface over it: one
    // dynamic library, so that what it links — FFmpeg, libass — is bound to
    // its own copies whatever else the app carries. One product for both
    // modules: as two, Xcode would carry UmbelCore inside the interface's
    // library as well, and cannot give it one of its own under the product's
    // name. A host imports UmbelCore, and UmbelUI where it wants it. The
    // optional network modules built here are in it too, for the same reason.
    .library(name: "UmbelCore", type: .dynamic, targets: ["UmbelCore", "UmbelUI"] + optionalModules.sourceTargets),
  ],
  targets: [
    // FFmpeg's five libraries as one, built LGPL-configured by
    // Tools/BuildFFmpeg/build.sh; its headers under <UmbelFFmpeg/libavutil/…>.
    .binaryTarget(name: "UmbelFFmpeg", path: "Binaries/UmbelFFmpeg.xcframework"),
    // libass with FreeType and HarfBuzz in it, and FriBidi (LGPL) a library of
    // its own, built from pinned sources by Tools/BuildLibass/build.sh.
    .binaryTarget(name: "UmbelASS", path: "Binaries/UmbelASS.xcframework"),
    .binaryTarget(name: "UmbelFriBidi", path: "Binaries/UmbelFriBidi.xcframework"),
    // The C modules over the frameworks' headers: `import FFmpeg`, `import
    // LibASS`. Declared here rather than in the binaries, where two
    // frameworks' module maps would land on each other in an app's build.
    .systemLibrary(name: "FFmpeg"),
    .systemLibrary(name: "LibASS"),
    .target(
      name: "UmbelFFmpegSupport",
      dependencies: ["FFmpeg", "UmbelFFmpeg"]
    ),
    .target(
      name: "UmbelASSSupport",
      dependencies: ["LibASS", "UmbelASS", "UmbelFriBidi"]
    ),
    // Catches Objective-C exceptions, which Swift cannot. See its header.
    .target(name: "UmbelObjCSupport"),
    // The shader sources are resources, compiled by the renderer when it
    // starts. Named .metalsrc rather than .metal: Xcode would compile a .metal
    // file itself, copy declared or not — with a toolchain it may not have,
    // and leaving no source for the renderer to find.
    .target(
      name: "UmbelCore",
      dependencies: ["UmbelFFmpegSupport", "UmbelASSSupport", "UmbelObjCSupport"],
      resources: [
        .copy("Video/Shaders/video.metalsrc"),
        .copy("Video/Shaders/subtitle_overlay.metalsrc"),
        .copy("Video/Shaders/deinterlace.metalsrc"),
        .copy("Notices/Texts"),
        // Why it uses the system interfaces Apple asks a reason for.
        .copy("PrivacyInfo.xcprivacy"),
      ]
    ),
    .target(name: "UmbelUI", dependencies: ["UmbelCore"]),
    // The tests build FFmpegStreamInfo themselves to drive track mapping, so
    // they declare it outright rather than lean on SwiftPM's transitive
    // visibility — an implementation detail, not a contract.
    .testTarget(
      name: "UmbelCoreTests",
      dependencies: ["UmbelCore", "UmbelFFmpegSupport", "UmbelASSSupport"]
    ),
    .testTarget(
      name: "UmbelFFmpegSupportTests",
      dependencies: ["UmbelFFmpegSupport"]
    ),
    .testTarget(
      name: "UmbelASSSupportTests",
      dependencies: ["UmbelASSSupport"]
    ),
    .testTarget(
      name: "UmbelUITests",
      dependencies: ["UmbelUI", "UmbelCore"]
    ),
    // The smallest command-line example. Real audio output cannot be checked
    // automatically; acceptance by hand runs on this.
    .executableTarget(
      name: "umbel-video-fidelity-check",
      dependencies: ["UmbelCore", "UmbelFFmpegSupport"],
      path: "Tools/VideoFidelityCheck",
      exclude: ["README.md"]
    ),
    .executableTarget(
      name: "umbel-play",
      dependencies: ["UmbelCore", "UmbelUI"],
      path: "Examples/UmbelPlay"
    ),
    // Acceptance against an HTTP/2 connection that goes silent; it needs a
    // relay run by Node.js, so it is built here but run by hand. See
    // Tools/SilentConnectionCheck/README.md.
    .executableTarget(
      name: "umbel-silent-connection-check",
      dependencies: ["UmbelCore"],
      path: "Tools/SilentConnectionCheck/Check"
    ),
  ] + optionalModules.targets
)
