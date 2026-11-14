import AVFoundation
import UIKit
import UmbelCore

/// The smallest iOS player: one screen, for checking the engine on an iPad —
/// picture in picture, sound going on in the background, the audio session.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if ProcessInfo.processInfo.arguments.contains("-transport-tests") {
      let window = UIWindow(frame: UIScreen.main.bounds)
      window.rootViewController = UIViewController()
      window.makeKeyAndVisible()
      self.window = window
      return true
    }
    // Playback, so sound goes on with the screen locked, in the background
    // and in picture in picture.
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    // Multichannel sound handed on as it is, for the system to spatialize on
    // headphones that can; otherwise it is folded to stereo first.
    try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(true)
    try? AVAudioSession.sharedInstance().setActive(true)
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = PlayerViewController(options: LaunchOptions())
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}

/// What to play and do, from the launch arguments — the simulator takes no
/// taps from a script:
///
///     -url <address or path>   what to play (a public test stream otherwise);
///                              a relative path is inside the app's container
///     -seek <seconds>          where to start
///     -rate <speed>            how fast
///     -pip <seconds>           open picture in picture that long after playing
///     -pipfor <seconds>        and close it again that long after
///     -sample                  show the picture in picture layer in place of
///                              the Metal one, to check it draws
///     -subtitle <path>         an external subtitle in the app's container
///     -commands <path>         a JSON command file copied into the container
///     -mainstall <seconds>     block the main thread every two seconds
///     -main-display            use the main-thread reference display loop
///     -diagnostics             export timestamp observations as JSON lines
///     -engine-audio            use the audio engine's sample clock
///     -background-decoding     keep decoding the picture in the background, as
///                              a host does while picture in picture is still
///                              starting: the system then takes the hardware
///                              decoder away, and coming back must recover
struct LaunchOptions {
  var url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8")!
  var seek: Double?
  var rate: Double?
  var pictureInPictureAfter: Double?
  var pictureInPictureFor: Double?
  var sampleLayerInPlace = false
  var subtitleURL: URL?
  var commandsURL: URL?
  var mainThreadStall: Double?
  var mainThreadDisplay = false
  /// `-no-object-audio`: E-AC-3 with objects decoded here too.
  var objectAudio = UmbelObjectAudioMode.automatic
  /// `-muted`: silent from the start, for checks run with no one listening.
  var muted = false
  var backgroundDecoding = false
  /// `-buffer-target seconds`: how far ahead to read; the default is ten.
  var bufferTarget: Double?
  var timestampDiagnostics = false
  var engineAudio = false

  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    func value(_ name: String) -> String? {
      guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
      return arguments[index + 1]
    }
    func localFile(_ path: String) -> URL {
      URL(fileURLWithPath: path, relativeTo: path.hasPrefix("/") ? nil
          : URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)).absoluteURL
    }
    if let text = value("-url") {
      // A relative path is the app's own: files copied into its container.
      url = text.contains("://") ? (URL(string: text) ?? url)
        : localFile(text)
    }
    seek = value("-seek").flatMap(Double.init)
    rate = value("-rate").flatMap(Double.init)
    pictureInPictureAfter = value("-pip").flatMap(Double.init)
    pictureInPictureFor = value("-pipfor").flatMap(Double.init)
    sampleLayerInPlace = arguments.contains("-sample")
    subtitleURL = value("-subtitle").map(localFile)
    commandsURL = value("-commands").map(localFile)
    mainThreadStall = value("-mainstall").flatMap(Double.init)
      .flatMap { $0.isFinite && $0 > 0 ? min($0, 1) : nil }
    mainThreadDisplay = arguments.contains("-main-display")
    if arguments.contains("-no-object-audio") { objectAudio = .off }
    muted = arguments.contains("-muted")
    backgroundDecoding = arguments.contains("-background-decoding")
    bufferTarget = value("-buffer-target").flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    timestampDiagnostics = arguments.contains("-diagnostics")
    engineAudio = arguments.contains("-engine-audio")
  }
}
