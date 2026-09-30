#!/bin/bash
# iOS 27 / Xcode 27 actual VoiceOver speech and focus checks, with local fixtures.
set -euo pipefail
if [ "$#" -lt 2 ]; then
  echo 'Usage: scripts/test-voiceover.sh SIMULATOR_UDID NEW_OUTPUT_DIRECTORY [DERIVED_DATA_DIRECTORY] [TEST_IDENTIFIER]' >&2
  exit 2
fi
repository=$(cd "$(dirname "$0")/.." && pwd)
simulator="$1"
mkdir -p "$2"
output=$(cd "$2" && pwd)
if [ -e "$output/voiceover.xcresult" ]; then echo 'Use a fresh output directory.' >&2; exit 2; fi
fixture="$output/fixture"
mkdir -p "$fixture"
python3 - "$repository" "$fixture" <<'PY'
import json, pathlib, re, shutil, sys
repo, fixture = map(pathlib.Path, sys.argv[1:])
project = fixture / 'RemoteFiles.xcodeproj'
shutil.copytree(repo / 'RemoteFiles.xcodeproj', project)
pbx = project / 'project.pbxproj'
s = pbx.read_text().replace('relativePath = .;', 'relativePath = ' + json.dumps(str(repo)) + ';')
replacements = {
    'App/RemoteFilesApp.swift': 'Tests/VoiceOverFixtures/RemoteFilesAccessibilityApp.swift',
    'Tests/RemoteFilesUITests/RemoteFilesUITests.swift': 'Tests/VoiceOverFixtures/VoiceOverUITests.swift',
}
def absolute_source(m):
    relative = m.group(1).strip('"')
    if relative.endswith('.swift'):
        return 'path = ' + json.dumps(str(repo / replacements.get(relative, relative))) + '; sourceTree = SOURCE_ROOT;'
    return m.group(0)
s = re.sub(r'path = ("[^"]+"|[^;]+); sourceTree = SOURCE_ROOT;', absolute_source, s)
pbx.write_text(s)
PY
derived="${3:-$output/DerivedData}"
test_identifier="${4:-RemoteFilesUITests/VoiceOverChecks}"
# The fixture app replaces only the entry point in a disposable project; its
# reader and image views are the current production package. It contains no
# private files and never opens the documentation link. Tests restore the
# simulator's original VoiceOver enabled state in an XCTest teardown block.
xcodebuild -project "$fixture/RemoteFiles.xcodeproj" -scheme RemoteFiles \
  -configuration Debug -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath "$derived" -resultBundlePath "$output/voiceover.xcresult" \
  -only-testing:"$test_identifier" -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 240 -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test > "$output/voiceover.log" 2>&1
