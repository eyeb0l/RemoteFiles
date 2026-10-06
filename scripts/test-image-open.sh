#!/bin/bash
# Exercise production Markdown parsing, Open file, retry and dismissal with local metadata fixtures.
set -euo pipefail
simulator="${1:?Usage: test-image-open.sh SIMULATOR_UDID FRESH_OUTPUT_DIRECTORY [DERIVED_DATA] [SOURCE_PACKAGES]}"
output="${2:?Supply a fresh output directory}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -e "$output" ]; then
  echo 'Use a fresh output directory to preserve earlier test evidence.' >&2
  exit 1
fi
mkdir -p "$output"
output="$(cd "$output" && pwd)"
derived="${3:-$output/DerivedData}"
packages="${4:-$output/SourcePackages}"
python3 - "$repo" "$output" <<'PY'
from pathlib import Path
import json
import re
import shutil
import sys

root, output = map(Path, sys.argv[1:])
project = output / 'RemoteFiles.xcodeproj'
shutil.copytree(root / 'RemoteFiles.xcodeproj', project)
pbx = project / 'project.pbxproj'
source = pbx.read_text().replace('relativePath = .;', 'relativePath = ' + json.dumps(str(root)) + ';')
def replace(match):
    relative = match[1].strip('"')
    if not relative.endswith(('.swift', '.icon')):
        return match[0]
    overrides = {
        'App/RemoteFilesApp.swift': 'Tests/VoiceOverFixtures/RemoteFilesAccessibilityApp.swift',
        'Tests/RemoteFilesUITests/RemoteFilesUITests.swift': 'Tests/ImageOpenFixtures/ImageOpenUITests.swift',
    }
    path = root / overrides.get(relative, relative)
    return 'path = ' + json.dumps(str(path)) + '; sourceTree = SOURCE_ROOT;'
pbx.write_text(re.sub(r'path = ("[^\"]+"|[^;]+); sourceTree = SOURCE_ROOT;', replace, source))
PY
plutil -lint "$output/RemoteFiles.xcodeproj/project.pbxproj"
xcodebuild -project "$output/RemoteFiles.xcodeproj" -scheme RemoteFiles \
  -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$derived" \
  -clonedSourcePackagesDirPath "$packages" -onlyUsePackageVersionsFromResolvedFile \
  -jobs 2 -collect-test-diagnostics never -parallel-testing-enabled NO \
  -resultBundlePath "$output/tests.xcresult" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  -only-testing:RemoteFilesUITests/ImageOpenUITests test
