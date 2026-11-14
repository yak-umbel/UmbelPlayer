# The tests whose verdict depends on real time: the system player's clock, an
# audio device's clock, or a wait measured in wall-clock seconds.
#
# Sourced by Tools/ci.sh and Tools/check_realtime_tests.sh, never run. On a
# hosted runner these are the tests that can fail with nothing wrong in the
# code: the machine is virtual, its sleeps wake late, its audio device has no
# latency. So the runner runs them as a step of their own that does not decide
# the result (see .github/workflows/ci.yml). A developer machine runs them with
# everything else: Tools/ci.sh with no argument.
#
# A class belongs here when it has failed on the runner with the code unchanged
# and its verdict comes from a real clock, not when it merely takes long. To add
# one, put its name below; Tools/check_realtime_tests.sh then confirms that
# every name still matches a test.
UMBEL_REALTIME_CLASSES=(
  GeneratedSegmentPlaybackTests
  HTTPTransportTests
  ObjectAudioRouteTests
  ObjectAudioSessionTests
  OfflinePatiencePlaybackTests
  PlayerItemTimelineTests
  SampleBufferAudioDeviceTests
  SystemTimelineClockTests
)
UMBEL_REALTIME_MODULE="UmbelCoreTests"

# A regular expression over "Module.Class/test", for swift test --filter (the
# group) and --skip (everything else).
UMBEL_REALTIME_TESTS="^${UMBEL_REALTIME_MODULE}\\.($(IFS='|'; echo "${UMBEL_REALTIME_CLASSES[*]}"))/"
