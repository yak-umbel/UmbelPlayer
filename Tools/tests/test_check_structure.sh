#!/bin/bash
# Cases for Tools/check_structure.sh.
#
# The guard runs on a copy in a scratch skeleton, so planted offences touch
# nothing real and the real repository's state cannot interfere.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../check_structure.sh"
FAILURES=0

echo "test_check_structure"

# The smallest skeleton that passes: Sources/<target>/<subdirectory>/ and its
# Tests directory.
make_repo() {
  local root="$1"
  mkdir -p "$root/Tools"
  mkdir -p "$root/Sources/UmbelCore/Demux"
  mkdir -p "$root/Tests/UmbelCoreTests/Demux"
  printf 'public enum Ok {}\n' > "$root/Sources/UmbelCore/Demux/Ok.swift"
  cp "$SCRIPT" "$root/Tools/check_structure.sh" 2>/dev/null
  cp "$HERE/../find_cjk.py" "$root/Tools/find_cjk.py" 2>/dev/null
  chmod +x "$root/Tools/check_structure.sh" 2>/dev/null
}

expect_exit() {
  local label="$1" want="$2" root="$3"
  "$root/Tools/check_structure.sh" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  ✓ $label"
  else
    echo "  ✗ ${label}: expected exit ${want}, got $got"
    FAILURES=$((FAILURES + 1))
  fi
}

run_case() {
  local label="$1" want="$2" setup="$3"
  local root
  root="$(mktemp -d)"
  make_repo "$root"
  eval "$setup"
  expect_exit "$label" "$want" "$root"
  rm -rf "$root"
}

run_case "a clean skeleton passes" 0 'true'

run_case "an overlong file is refused" 1 \
  'seq 1 401 | sed "s/^/\/\/ line /" > "$root/Sources/UmbelCore/Demux/Long.swift"'

run_case "import FFmpeg in UmbelCore is refused" 1 \
  'printf "import FFmpeg\n" > "$root/Sources/UmbelCore/Demux/Bad.swift"'

run_case "AVFormatContext in UmbelCore is refused" 1 \
  'printf "let ctx: AVFormatContext? = nil\n" > "$root/Sources/UmbelCore/Demux/Bad.swift"'

run_case "av_read_frame in UmbelCore is refused" 1 \
  'printf "av_read_frame(a, b)\n" > "$root/Sources/UmbelCore/Demux/Bad.swift"'

run_case "import AVFoundation passes (Apple's framework is not FFmpeg)" 0 \
  'printf "import AVFoundation\nlet e: AVAudioEngine? = nil\n" > "$root/Sources/UmbelCore/Demux/Ok2.swift"'

run_case "mutable global state is refused" 1 \
  'printf "enum A { static var counter = 0 }\n" > "$root/Sources/UmbelCore/Demux/Bad.swift"'

run_case "a computed static property passes (it is not stored state)" 0 \
  'printf "enum A { static var name: String { \"x\" } }\n" > "$root/Sources/UmbelCore/Demux/Ok2.swift"'

run_case "a missing test directory is refused" 1 \
  'mkdir -p "$root/Sources/UmbelCore/Source"; printf "public enum S {}\n" > "$root/Sources/UmbelCore/Source/S.swift"'

run_case "a C or Objective-C include directory needs no test directory" 0 \
  'mkdir -p "$root/Sources/UmbelObjC/include"; printf "void f(void);\n" > "$root/Sources/UmbelObjC/include/f.h"'

run_case "other subdirectories still need one" 1 \
  'mkdir -p "$root/Sources/UmbelObjC/include" "$root/Sources/UmbelObjC/Bridge"; printf "public enum B {}\n" > "$root/Sources/UmbelObjC/Bridge/B.swift"'

run_case "a target without subdirectories needs no test directory" 0 \
  'mkdir -p "$root/Sources/UmbelUI"; printf "public enum UI {}\n" > "$root/Sources/UmbelUI/UI.swift"'

run_case "a Chinese comment in Sources is refused" 1 \
  'printf "// 中文注释\nlet a = 1\n" > "$root/Sources/UmbelCore/Demux/Bad.swift"'

run_case "a Chinese string in Sources is refused" 1 \
  'printf "let a = \"失败\"\n" > "$root/Sources/UmbelCore/Demux/Bad.swift"'

run_case "a Chinese comment in Tests is refused" 1 \
  'printf "/* 说明\n */\nlet a = 1\n" > "$root/Tests/UmbelCoreTests/Demux/BadTests.swift"'

run_case "Chinese test data in Tests passes" 0 \
  'printf "let text = \"中文字幕 // 不是注释\"\n" > "$root/Tests/UmbelCoreTests/Demux/DataTests.swift"'

run_case "a Chinese comment in a Tools script is refused" 1 \
  'printf "#!/bin/bash\necho hi  # 打个招呼\n" > "$root/Tools/x.sh"'

run_case "Chinese data in a Tools script passes" 0 \
  'printf "#!/bin/bash\necho \"中文 # 不是注释\"\n" > "$root/Tools/x.sh"'

run_case "a Chinese comment in a Tools file with no extension is refused" 1 \
  'printf "# 名称 版本\nlibass 0.17.5\n" > "$root/Tools/VERSIONS"'

run_case "a binary file with no extension is not read as text" 0 \
  'printf "\\x47\\x00\\x11 # 中文\\n" > "$root/Tests/UmbelCoreTests/Demux/segment0"'

run_case "a Chinese comment in the package manifest is refused" 1 \
  'printf "// 清单\nlet a = 1\n" > "$root/Package.swift"'

run_case "a Chinese comment in a workflow is refused" 1 \
  'mkdir -p "$root/.github/workflows"; printf "# 构建\nname: CI\n" > "$root/.github/workflows/ci.yml"'

run_case "a Chinese comment in .gitignore is refused" 1 \
  'printf "# 片源\nvideos/\n" > "$root/.gitignore"'

run_case "English settings pass" 0 \
  'printf "// Manifest\n" > "$root/Package.swift"; printf "# Media\nvideos/\n" > "$root/.gitignore"'

if [ "$FAILURES" -eq 0 ]; then
  echo "✓ all passed"
  exit 0
fi
echo "✗ ${FAILURES} failed"
exit 1
