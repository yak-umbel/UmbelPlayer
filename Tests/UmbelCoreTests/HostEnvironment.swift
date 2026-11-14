import Foundation

/// What machine the tests run on, for the few that depend on real hardware.
enum HostEnvironment {
  /// Whether this is a virtual machine, as a hosted CI runner is; the system
  /// says so itself. Such a machine reports video decoders it cannot use and
  /// sound devices with no latency, so tests of how hardware behaves have
  /// nothing to say there.
  static let isVirtualMachine: Bool = {
    var present: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0 && present == 1
  }()
}
