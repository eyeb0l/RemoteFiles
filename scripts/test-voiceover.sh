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
s = s.replace('INFOPLIST_FILE = App/Info.plist;', 'INFOPLIST_FILE = ' + json.dumps(str(repo / 'App/Info.plist')) + ';')
replacements = {
    'App/RemoteFilesApp.swift': 'Tests/VoiceOverFixtures/RemoteFilesAccessibilityApp.swift',
    'Tests/RemoteFilesUITests/RemoteFilesUITests.swift': 'Tests/VoiceOverFixtures/VoiceOverUITests.swift',
}
def absolute_source(m):
    relative = m.group(1).strip('"')
    if relative.endswith(('.swift', '.icon')):
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
package_options=()
if [ -n "${REMOTEFILES_SOURCE_PACKAGES_DIR:-}" ]; then
  package_options=(-clonedSourcePackagesDirPath "$REMOTEFILES_SOURCE_PACKAGES_DIR" -onlyUsePackageVersionsFromResolvedFile)
fi
ci_options=()
if [ -n "${REMOTEFILES_CI_COMPILATION_CACHE:-}" ]; then
  ci_options=(COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES
    "COMPILATION_CACHE_CAS_PATH=$REMOTEFILES_CI_COMPILATION_CACHE" COMPILER_INDEX_STORE_ENABLE=NO)
fi
# Bash 3.2 treats empty arrays as unset under nounset; retain quoting when populated.
if xcodebuild -jobs 2 -project "$fixture/RemoteFiles.xcodeproj" -scheme RemoteFiles ${package_options[@]+"${package_options[@]}"} ${ci_options[@]+"${ci_options[@]}"} \
  -configuration Debug -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath "$derived" -resultBundlePath "$output/voiceover.xcresult" \
  -only-testing:"$test_identifier" -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 240 -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test > "$output/voiceover.log" 2>&1; then
  test_status=0
else
  test_status=$?
fi
if [ "$test_status" -ne 0 ]; then
  # Only this preview category is public, content-free lifecycle state. Keep the
  # original XCTest failure even if Simulator log collection also fails.
  xcrun simctl spawn "$simulator" log show --last 30m --style compact --info \
    --predicate 'subsystem == "dev.iris.RemoteFiles" AND category == "SVGPreview"' \
    > "$output/svg-rendering.log" 2>&1 || true
fi
exit "$test_status"
