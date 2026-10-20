#!/bin/bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
timeout 20 xcodebuildmcp swift-package build --package-path "$project_root/Core"
build_directory="$project_root/Core/.build/$(uname -m)-apple-macosx/debug"
test_directory=$(mktemp -d /tmp/cubic-architecture-tests.XXXXXX)
trap 'rm -rf "$test_directory"' EXIT
timeout 20 swiftc -swift-version 6 -parse-as-library \
    -I "$build_directory/Modules" -I Core/Sources/CSQLite3 \
    CubicApp/RiskNotices.swift CubicApp/SystemServices.swift CubicApp/Design.swift \
    CubicApp/WorkspaceSession.swift CubicApp/PlanningChoiceConfirmation.swift CubicApp/CalendarBridge.swift \
    Tests/Architecture/ArchitectureOperationTests.swift \
    "$build_directory"/CubicCore.build/*.o -lsqlite3 \
    -o "$test_directory/architecture-tests"
timeout 20 "$test_directory/architecture-tests"
