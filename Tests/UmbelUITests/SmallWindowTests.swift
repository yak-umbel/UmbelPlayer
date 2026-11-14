#if os(macOS)
import AppKit
import XCTest
@testable import UmbelUI

/// The system's small window, as its class is named on macOS.
private final class PIPPanel: NSWindow {}

/// The system's leftover view in the small window, as its class is named.
private final class AVPictureInPictureCALayerHostView: NSView {}

/// Which window is picture in picture's small one: on macOS the layer takes
/// its size, so taking another would size the picture wrong.
@MainActor
final class SmallWindowTests: XCTestCase {
  private func window<W: NSWindow>(_ type: W.Type) -> W {
    W(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
  }

  /// Another window opening at the same moment is not taken for it.
  func testThePanelIsTakenOverAnotherNewWindow() {
    let old = window(NSWindow.self), other = window(NSWindow.self), panel = window(PIPPanel.self)
    let found = UmbelPictureInPicture.smallWindow(
      among: [old, other, panel], before: [ObjectIdentifier(old)])
    XCTAssertTrue(found === panel)
  }

  /// Named otherwise on some system to come, the one new window is taken.
  func testWithoutAPanelTheNewWindowIsTaken() {
    let old = window(NSWindow.self), new = window(NSWindow.self)
    let found = UmbelPictureInPicture.smallWindow(among: [old, new], before: [ObjectIdentifier(old)])
    XCTAssertTrue(found === new)
  }

  /// The small window lays a black view over the picture — solid, scaled
  /// down, its top part showing over the video's top: a black band across
  /// the small window, a tenth of it for a wide film, half for a 4:3 one.
  /// It is hidden, wherever it sits; the rest is left alone.
  func testTheBlackViewOverThePictureIsHidden() {
    let content = NSView(), host = NSView(), video = NSView()
    let black = AVPictureInPictureCALayerHostView()
    content.addSubview(host)
    host.addSubview(video)
    host.addSubview(black)
    UmbelPictureInPicture.hideBlackCover(in: content)
    XCTAssertTrue(black.isHidden)
    XCTAssertFalse(host.isHidden, "the view carrying the picture stays")
    XCTAssertFalse(video.isHidden)
  }

  /// Given the small window's size, the layer sits in the middle of where it
  /// was: the window's placeholder for the picture is centred, not pushed to
  /// a corner. Where it sits does not change the small window.
  func testTheLayerIsCentredWhereItWas() {
    let frame = UmbelPictureInPicture.centred(CGSize(width: 400, height: 300), in: CGRect(x: 0, y: 0, width: 1000, height: 700))
    XCTAssertEqual(frame, CGRect(x: 300, y: 200, width: 400, height: 300))
  }

  /// A panel that was there before is not the one that just opened.
  func testAnOldPanelIsNotTaken() {
    let oldPanel = window(PIPPanel.self)
    let found = UmbelPictureInPicture.smallWindow(among: [oldPanel], before: [ObjectIdentifier(oldPanel)])
    XCTAssertNil(found)
  }
}
#endif
