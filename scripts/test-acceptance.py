#!/usr/bin/env python3
"""Run acceptance from an immutable source snapshot and retain evidence.

Requires Xcode 27, Swift 6, Python 3, and an available iOS 27 simulator.
Uses only disposable local files/SSH keys and a loopback-only sshd.
"""
import time

MODULE_STARTED = time.monotonic()

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys


# Simulator filesystems cannot establish physical-device Data Protection classes. The Face ID
# checks are opt-in: one needs a host-sent biometric match, the other a physical device.
SIMULATOR_ALLOWED_SKIPS = {
    "IdentityTests/testTrustStoreWritesUseCompleteFileProtection",
    "IdentityTests/testSimulatedFaceIDReadsTheStoredKey",
    "IdentityTests/testSimulatedEnrolmentChangeInvalidatesTheStoredKey",
}
DEFAULT_LANES = ("macos-openssh", "simulator", "voiceover", "release-device-compile")
AVAILABLE_LANES = DEFAULT_LANES + ("simulator-core", "simulator-ui")


def timed(phases, name, operation):
    started = time.monotonic()
    phase = {"name": name, "started_utc": datetime.now(timezone.utc).isoformat(),
             "load_before": list(os.getloadavg()), "status": "failed"}
    phases.append(phase)
    print("Starting phase: " + name, flush=True)
    try:
        result = operation()
        phase["status"] = "passed"
        return result
    finally:
        phase["seconds"] = round(time.monotonic() - started, 3)
        phase["load_after"] = list(os.getloadavg())
        print("Phase " + name + ": " + phase["status"] + " (" + str(phase["seconds"]) + "s)", flush=True)


def ci_build_settings(cache):
    if cache is None:
        return []
    return ["COMPILATION_CACHE_ENABLE_CACHING=YES", "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES",
            "COMPILATION_CACHE_CAS_PATH=" + str(cache), "COMPILER_INDEX_STORE_ENABLE=NO"]


def boot_selected_simulator(run, simulator):
    # CI created this specific disposable device without booting it. Never touch
    # any other Simulator, and leave retirement to the composite's always step.
    log = run.output / "simulator-boot.log"
    def boot():
        with log.open("w") as handle:
            for command, timeout in ((["xcrun", "simctl", "boot", simulator], 60),
                                     (["xcrun", "simctl", "bootstatus", simulator, "-b"], 300)):
                subprocess.run(command, stdout=handle, stderr=subprocess.STDOUT, check=True, timeout=timeout)
    timed(run.metadata["phases"], "simulator-boot", boot)
    inventory = json.loads(capture(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    write_json(run.output / "simulator-after-boot.json", inventory)


def selected_lanes(requested):
    lanes = tuple(dict.fromkeys(requested or DEFAULT_LANES))
    if "simulator" in lanes and any(lane in lanes for lane in ("simulator-core", "simulator-ui")):
        raise ValueError("Choose the combined simulator lane or its core/UI lanes, not both")
    return lanes


def capture(command, cwd=None):
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def source_files(repo):
    return sorted(set(subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=repo
    ).decode().split("\0")) - {""})


def manifest(repo, files):
    entries = []
    for relative in files:
        path = repo / relative
        if not path.exists() and not path.is_symlink():
            continue  # A tracked deletion is represented by its absence and the patch.
        if path.is_symlink():
            data, kind = os.readlink(path).encode(), "symlink"
        elif path.is_file():
            data, kind = path.read_bytes(), "file"
        else:
            raise RuntimeError("Unsupported source entry (e.g. submodule): " + relative)
        entries.append({"path": relative, "kind": kind, "executable": bool(path.lstat().st_mode & 0o111),
                        "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    return entries


def tree_hash(entries):
    return hashlib.sha256(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def snapshot(repo, output, allow_dirty, use_checkout=False):
    head = capture(["git", "rev-parse", "HEAD"], repo)
    status = capture(["git", "status", "--porcelain=v1", "--untracked-files=all"], repo)
    if use_checkout and (status or allow_dirty):
        raise RuntimeError("Direct checkout validation requires a clean, dedicated checkout; do not use --allow-dirty")
    if status and not allow_dirty:
        raise RuntimeError("Working tree is dirty. Commit tested changes or pass --allow-dirty to identify the exact snapshot.")
    files = source_files(repo)
    before = manifest(repo, files)
    for entry in before:
        if entry["kind"] == "symlink" and not (repo / entry["path"]).resolve().is_relative_to(repo):
            raise RuntimeError("Source symlink escapes repository: " + entry["path"])
    target = repo if use_checkout else output / "source"
    if not use_checkout:
        target.mkdir()
        for entry in before:
            src, dst = repo / entry["path"], target / entry["path"]
            dst.parent.mkdir(parents=True, exist_ok=True)
            if entry["kind"] == "symlink":
                dst.symlink_to(os.readlink(src))
            else:
                shutil.copy2(src, dst)
    after = manifest(repo, source_files(repo))
    if before != after or (not use_checkout and manifest(target, files) != before) or capture(["git", "rev-parse", "HEAD"], repo) != head:
        raise RuntimeError("Source changed during snapshot. Re-run after concurrent edits finish.")
    patch = subprocess.check_output(["git", "diff", "--binary", "HEAD"], cwd=repo)
    (output / "source.patch").write_bytes(patch)
    (output / "source-status.txt").write_text(status + "\n")
    write_json(output / "source-manifest.json", before)
    return target, {"commit": head, "git_tree": capture(["git", "rev-parse", "HEAD^{tree}"], repo),
                    "branch": capture(["git", "branch", "--show-current"], repo), "dirty": bool(status),
                    "mode": "working-tree snapshot" if status else "exact commit",
                    "source_tree_sha256": tree_hash(before), "patch_sha256": hashlib.sha256(patch).hexdigest(),
                    "source_capture": "dedicated checkout" if use_checkout else "immutable copy"}


def expected_tests(root, platform, directories):
    """Fail closed on unrecognized conditionals or a test outside a known class.

    This small repository uses XCTest methods and os(iOS)/os(macOS) conditionals.
    Source inventory catches a new test file omitted from the Xcode project.
    """
    tests = set()
    for directory in directories:
        for path in sorted((root / directory).glob("*.swift")):
            active, stack, classname = True, [], None
            for line in path.read_text().splitlines():
                directive = re.match(r"\s*#(if|elseif|else|endif)\b(.*)", line)
                if directive:
                    kind, expression = directive.groups()
                    if kind in ("if", "elseif"):
                        condition = re.fullmatch(r"\s*os\((iOS|macOS)\)\s*", expression)
                        if not condition:
                            raise RuntimeError("Unrecognized test conditional in " + str(path) + ": " + line)
                        selected = condition[1] == platform
                    if kind == "if":
                        stack.append([active, selected])
                        active = active and selected
                    elif kind == "elseif":
                        parent, previous = stack[-1]
                        active = parent and not previous and selected
                        stack[-1][1] = previous or selected
                    elif kind == "else":
                        parent, previous = stack[-1]
                        active = parent and not previous
                        stack[-1][1] = True
                    else:
                        active = stack.pop()[0]
                    continue
                if not active:
                    continue
                cls = re.search(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b|\bextension\s+(\w+)\s*\{", line)
                if cls:
                    classname = cls[1] or cls[2]
                method = re.search(r"\bfunc\s+(test\w+)\s*\(", line)
                if method:
                    if not classname:
                        raise RuntimeError("Test without inventoried XCTest class: " + str(path))
                    identifier = classname + "/" + method[1]
                    if identifier in tests:
                        raise RuntimeError("Duplicate test identifier: " + identifier)
                    tests.add(identifier)
            if stack:
                raise RuntimeError("Unbalanced test conditionals: " + str(path))
    if not tests:
        raise RuntimeError("No expected tests inventoried for " + platform)
    return tests


def log_tests(path):
    tests = {}
    # Simulator diagnostics may split an XCTest identifier or appear between
    # its outcome and duration. Remove only complete, structured runtime log
    # records inside the identifier; unknown interruptions still fail inventory.
    diagnostic = re.compile(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+[+-]\d{4} "
                            r"[\w.-]+\[\d+:\d+\] \[[^\]\n]+\] [^\n]*\n")
    pattern = re.compile(r"Test Case '-\[(?:[\w]+\.)?(\w+) (test\w+)\]' (passed|failed|skipped)(?=\s|$|\d{4}-\d{2}-\d{2} )")
    for fragment in path.read_text(errors="replace").split("Test Case '-[")[1:]:
        name, closing, remainder = fragment.partition("]'")
        if not closing:
            continue
        match = pattern.match("Test Case '-[" + diagnostic.sub("", name) + closing + remainder)
        if not match:
            continue
        identifier = match[1] + "/" + match[2]
        if identifier in tests:
            raise RuntimeError("Repeated result (retries are not acceptance): " + identifier)
        tests[identifier] = match[3]
    return tests


class Run:
    def __init__(self, root, output, metadata, timeout=1800):
        self.root, self.output, self.metadata = root, output, metadata
        self.timeout = timeout
        self.lanes = []
        self.complete = False
        self.measure_resources = False
        self.env = dict(os.environ)
        # A caller's opt-in real-server environment must never expand this runner's scope.
        for key in list(self.env):
            if key.startswith(("REMOTEFILES_REAL_", "TEST_RUNNER_REMOTEFILES_REAL_")):
                del self.env[key]
        self.env["REMOTEFILES_REAL_SERVER"] = "0"
        self.env["TEST_RUNNER_REMOTEFILES_REAL_SERVER"] = "0"
        # Exercise the opt-in operations once against this runner's disposable
        # fixture. These timings are a smoke check, not a network-latency claim.
        for key, value in {"REMOTEFILES_BENCHMARK": "1", "REMOTEFILES_BENCHMARK_RUNS": "1",
                           "REMOTEFILES_BENCHMARK_LABEL": "acceptance-loopback"}.items():
            self.env[key] = value
            self.env["TEST_RUNNER_" + key] = value

    def command(self, name, command, cwd=None, log=None):
        path = log or self.output / (name + ".log")
        print("Starting " + name + ": " + shlex.join(map(str, command)), flush=True)
        started = time.monotonic()
        errors = []
        invocation = list(map(str, command))
        resources = self.output / (name + "-resources.log")
        if self.measure_resources and sys.platform == "darwin":
            invocation = ["/usr/bin/time", "-l", "-o", str(resources)] + invocation
        # Lanes wrapped by scripts/test-openssh.sh retain the fixture's complete server log.
        env = dict(self.env, REMOTEFILES_SSHD_LOG=str(self.output / (name + "-sshd.log")))
        with path.open("w") as handle:
            process = subprocess.Popen(invocation, cwd=cwd or self.root,
                                       env=env, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                exit_code = process.wait(timeout=self.timeout)
            except subprocess.TimeoutExpired:
                errors.append("Command exceeded " + str(self.timeout) + " seconds; its process group was interrupted")
                # Only this stage's process group is affected. Give the fixture's
                # EXIT/INT trap time to retire sshd and its generated keys/files.
                for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
                    try:
                        os.killpg(process.pid, sig)
                    except ProcessLookupError:
                        break
                    try:
                        process.wait(timeout=30 if sig == signal.SIGINT else 10)
                        break
                    except subprocess.TimeoutExpired:
                        continue
                exit_code = process.wait()
        lane = {"name": name, "command": list(map(str, command)), "exit_code": exit_code,
                "seconds": round(time.monotonic() - started, 3), "log": str(path),
                "status": "passed" if exit_code == 0 and not errors else "failed", "errors": errors}
        if resources.exists():
            lane["resource_log"] = str(resources)
        self.lanes.append(lane)
        print(name + ": " + lane["status"] + " (log: " + str(path) + ")", flush=True)
        self.save()
        return lane

    def tests(self, lane, expected, allowed_skips=(), xcresult=None):
        try:
            results = log_tests(Path(lane["log"]))
            missing, extra = sorted(expected - results.keys()), sorted(results.keys() - expected)
            if missing:
                lane["errors"].append("Missing results: " + ", ".join(missing))
            if extra:
                lane["errors"].append("Unexpected results: " + ", ".join(extra))
            unexpected_skips = [key for key, value in results.items() if value == "skipped" and key not in allowed_skips]
            if unexpected_skips:
                lane["errors"].append("Unexpected skips: " + ", ".join(unexpected_skips))
            if any(value == "failed" for value in results.values()):
                lane["errors"].append("One or more XCTest methods failed")
            lane["tests"] = results
            lane["expected_test_count"] = len(expected)
            lane["counts"] = dict(Counter(results.values()))
            suites = defaultdict(Counter)
            for key, value in results.items():
                suites[key.split("/")[0]][value] += 1
            lane["suites"] = {key: dict(value) for key, value in sorted(suites.items())}
            if xcresult:
                lane["xcresult"] = str(xcresult)
                summary_path = self.output / (lane["name"] + "-xcresult-summary.json")
                tests_path = self.output / (lane["name"] + "-xcresult-tests.json")
                for kind, path in [("summary", summary_path), ("tests", tests_path)]:
                    with path.open("w") as handle:
                        subprocess.run(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", str(xcresult)],
                                       stdout=handle, stderr=subprocess.PIPE, check=True)
                summary = json.loads(summary_path.read_text())
                actual = (summary["passedTests"], summary["failedTests"], summary["skippedTests"])
                counted = tuple(lane["counts"].get(key, 0) for key in ("passed", "failed", "skipped"))
                if actual != counted or summary["expectedFailures"]:
                    lane["errors"].append("xcresult/log count mismatch or expected failure: " + str(actual))
        except Exception as error:
            lane["errors"].append(str(error))
        if lane["errors"]:
            lane["status"] = "failed"
        counts = lane.get("counts", {})
        print(lane["name"] + ": " + lane["status"] + " " + str(counts), flush=True)
        for identifier, outcome in lane.get("tests", {}).items():
            if outcome == "failed":
                print("FAILED: " + identifier, flush=True)
        for error in lane["errors"]:
            print("ERROR: " + error, flush=True)
        if lane["status"] == "failed":
            # Make the first actionable assertions visible while later lanes run.
            log = Path(lane["log"])
            assertions = [line for line in (log.read_text(errors="replace").splitlines() if log.exists() else [])
                          if ": error:" in line]
            for line in assertions[:20]:
                print(line, flush=True)
        self.save()

    def save(self):
        report = {"schema_version": 1, "source": self.metadata, "lanes": self.lanes,
                  "status": ("failed" if any(lane["status"] == "failed" for lane in self.lanes) else
                             "passed" if self.complete else "running"),
                  "excluded": ["Physical iPhone and real-server UI acceptance (not authorized by this runner)"],
                  "human_acceptance": ["Physical device permission/lifecycle recovery", "Touch selection/copy and Save to Files destination",
                                       "VoiceOver touch gestures, rotor and Braille", "Sub-200 ms cached first display on physical hardware"]}
        write_json(self.output / "summary.json", report)
        lines = ["# RemoteFiles automated validation", "", "Requested lanes: " + ", ".join(self.metadata.get("requested_lanes", DEFAULT_LANES)), "", "Result: **" + report["status"] + "**", "",
                 "Source: `" + self.metadata["commit"] + "` (" + self.metadata["mode"] + ")",
                 "Source manifest SHA-256: `" + self.metadata["source_tree_sha256"] + "`", "",
                 "| Lane | Result | Passed | Failed | Skipped |", "|---|---|---:|---:|---:|"]
        for lane in self.lanes:
            counts = lane.get("counts", {})
            lines.append("| " + lane["name"] + " | " + lane["status"] + " | " + " | ".join(str(counts.get(k, "—")) for k in ("passed", "failed", "skipped")) + " |")
        if self.metadata.get("phases"):
            lines += ["", "## Runner phases", "", "| Phase | Result | Seconds |", "|---|---|---:|"]
            for phase in self.metadata["phases"]:
                lines.append("| " + phase["name"] + " | " + phase["status"] + " | " + str(phase.get("seconds", "running")) + " |")
        for lane in self.lanes:
            if lane.get("suites"):
                lines += ["", "## " + lane["name"], "", "| Suite | Passed | Failed | Skipped |", "|---|---:|---:|---:|"]
                for name, counts in lane["suites"].items():
                    lines.append("| " + name + " | " + " | ".join(str(counts.get(k, 0)) for k in ("passed", "failed", "skipped")) + " |")
            lines += ["", "Log: `" + lane["log"] + "`"]
            lines += ["- " + error for error in lane["errors"]]
        lines += ["", "## Deferred acceptance", ""] + ["- " + item for item in report["human_acceptance"]]
        lines += ["", "## Exclusions", ""] + ["- " + item for item in report["excluded"]]
        (self.output / "SUMMARY.md").write_text("\n".join(lines) + "\n")


def execute_lanes(run, lanes, packages, scratch, derived, simulator=None, boot_simulator=False, compilation_cache=None):
    root, output = run.root, run.output
    base = ["xcodebuild", "-jobs", "2", "-project", "RemoteFiles.xcodeproj", "-scheme", "RemoteFiles",
            "-clonedSourcePackagesDirPath", packages, "-onlyUsePackageVersionsFromResolvedFile", "-derivedDataPath", derived] + ci_build_settings(compilation_cache)
    if "macos-openssh" in lanes:
        mac = run.command("macos-openssh", ["scripts/test-openssh.sh", "swift", "test", "-j", "2", "--scratch-path", scratch, "--force-resolved-versions"])
        run.tests(mac, expected_tests(root, "macOS", ["Tests/RemoteFilesCoreTests"]))
    for lane in ("simulator", "simulator-core", "simulator-ui"):
        if lane not in lanes:
            continue
        directories = []
        selection = []
        if lane != "simulator-ui":
            directories.append("Tests/RemoteFilesCoreTests")
        if lane != "simulator-core":
            directories.append("Tests/RemoteFilesUITests")
        if lane == "simulator-core":
            selection = ["-only-testing:RemoteFilesTests"]
        elif lane == "simulator-ui":
            selection = ["-only-testing:RemoteFilesUITests"]
        expected = expected_tests(root, "iOS", directories)
        ordinary_skips = SIMULATOR_ALLOWED_SKIPS | {name for name in expected if name.startswith("RealServerUITests/")}
        sim_result = output / (lane + ".xcresult")
        simulator_base = list(base)
        action = "test"
        if lane == "simulator-core":
            simulator_base[simulator_base.index("-scheme") + 1] = "RemoteFilesCoreCI"
            build = run.command("simulator-core-build", simulator_base + ["-configuration", "Debug",
                "-destination", "generic/platform=iOS Simulator", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "build-for-testing"])
            if build["status"] != "passed":
                continue  # Never execute stale cached binaries after a failed build.
            if boot_simulator:
                boot_selected_simulator(run, simulator)
            action = "test-without-building"
        sim = run.command(lane, ["scripts/test-openssh.sh"] + simulator_base + ["-configuration", "Debug", "-destination", "platform=iOS Simulator,id=" + simulator,
            "-resultBundlePath", sim_result, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "180", "-maximum-test-execution-time-allowance", "240",
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"] + selection + [action])
        run.tests(sim, expected, ordinary_skips, sim_result)
    if "voiceover" in lanes:
        # The disposable fixture substitutes only app entry point and UI checks.
        run.env["REMOTEFILES_SOURCE_PACKAGES_DIR"] = str(packages)
        if compilation_cache is not None:
            run.env["REMOTEFILES_CI_COMPILATION_CACHE"] = str(compilation_cache)
        voice_dir = output / "voiceover"
        vo = run.command("voiceover", ["scripts/test-voiceover.sh", simulator, voice_dir, derived])
        vo["launcher_log"] = vo["log"]
        vo["log"] = str(voice_dir / "voiceover.log")
        run.tests(vo, expected_tests(root, "iOS", ["Tests/VoiceOverFixtures"]), xcresult=voice_dir / "voiceover.xcresult")
    if "release-device-compile" in lanes:
        run.command("release-device-compile", base + ["-configuration", "Release", "-destination", "generic/platform=iOS", "CODE_SIGNING_ALLOWED=NO", "build"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", help="Available iOS 27 simulator UDID; required for Simulator/VoiceOver lanes")
    parser.add_argument("--lane", choices=AVAILABLE_LANES, action="append",
                        help="Run only this lane (repeatable); default is all four acceptance lanes")
    parser.add_argument("--output", required=True, type=Path, help="Fresh evidence directory outside the repository")
    parser.add_argument("--use-checkout", action="store_true", help="Validate a dedicated clean checkout directly (CI), with source hashes checked before/after")
    parser.add_argument("--boot-simulator", action="store_true", help="Boot the selected disposable device after the core build; core-only CI lane")
    parser.add_argument("--ci-compilation-cache", type=Path, help="Enable CI compiler caching at this external CAS directory, disable indexing, and record resource usage")
    parser.add_argument("--allow-dirty", action="store_true", help="Capture current files with exact manifest/patch hashes")
    parser.add_argument("--source-packages", type=Path, help="Optional reusable Xcode locked-dependency checkout directory")
    parser.add_argument("--swift-scratch", type=Path, help="Optional reusable Swift build directory")
    parser.add_argument("--derived-data", type=Path, help="Optional reusable Xcode DerivedData directory")
    parser.add_argument("--port", type=int, default=22222, help="Disposable loopback sshd port (default 22222)")
    parser.add_argument("--timeout-minutes", type=int, default=30, help="Deadline per command, including build/test startup (default 30)")
    args = parser.parse_args()
    try:
        lanes = selected_lanes(args.lane)
    except ValueError as error:
        parser.error(str(error))
    if args.boot_simulator and lanes != ("simulator-core",):
        parser.error("--boot-simulator requires exactly --lane simulator-core")
    needs_simulator = any(lane.startswith("simulator") or lane == "voiceover" for lane in lanes)
    if needs_simulator and not args.simulator:
        parser.error("--simulator is required for the selected lanes")
    repo = Path(__file__).resolve().parents[1]
    output = args.output.expanduser().resolve()
    if output.is_relative_to(repo) or output.exists():
        parser.error("--output must be a fresh directory outside the repository")
    if not 1024 <= args.port <= 65535:
        parser.error("--port must be between 1024 and 65535")
    if args.timeout_minutes < 1:
        parser.error("--timeout-minutes must be positive")
    output.mkdir(parents=True)
    run = None
    phases = []
    try:
        module_seconds = round(time.monotonic() - MODULE_STARTED, 3)
        root, metadata = timed(phases, "source-preparation", lambda: snapshot(repo, output, args.allow_dirty, args.use_checkout))
        metadata["source_preparation_seconds"] = phases[-1]["seconds"]
        metadata["phases"] = phases
        metadata["module_initialization_seconds"] = module_seconds
        if os.environ.get("REMOTEFILES_RUNNER_LAUNCHED_AT"):
            metadata["shell_to_preparation_seconds"] = round(time.time() - float(os.environ["REMOTEFILES_RUNNER_LAUNCHED_AT"]) - phases[-1]["seconds"], 3)
        metadata["started_utc"] = datetime.now(timezone.utc).isoformat()
        metadata["xcode"] = timed(phases, "xcode-version", lambda: capture(["xcodebuild", "-version"]))
        metadata["swift"] = timed(phases, "swift-version", lambda: capture(["swift", "--version"]))
        metadata["requested_lanes"] = list(lanes)
        metadata["full_acceptance"] = set(DEFAULT_LANES).issubset(lanes)
        if needs_simulator:
            inventory = timed(phases, "simulator-inventory", lambda: json.loads(capture(["xcrun", "simctl", "list", "devices", "available", "-j"])))
            runtimes = timed(phases, "simulator-runtimes", lambda: json.loads(capture(["xcrun", "simctl", "list", "runtimes", "-j"])))
            device = [(runtime, device) for runtime, devices in inventory["devices"].items() for device in devices if device["udid"] == args.simulator]
            if len(device) != 1 or not device[0][0].startswith("com.apple.CoreSimulator.SimRuntime.iOS-27"):
                raise RuntimeError("Selected UDID is not an available iOS 27 simulator")
            metadata["simulator_runtime"], metadata["simulator"] = device[0]
            write_json(output / "simulator-inventory.json", inventory)
            write_json(output / "simulator-runtimes.json", runtimes)
        run = Run(root, output, metadata, timeout=args.timeout_minutes * 60)
        run.env["REMOTEFILES_TEST_PORT"] = str(args.port)
        run.measure_resources = args.ci_compilation_cache is not None
        compilation_cache = args.ci_compilation_cache.expanduser().resolve() if args.ci_compilation_cache else None
        if compilation_cache and compilation_cache.is_relative_to(root):
            raise RuntimeError("Compilation cache must be outside captured source")
        if run.measure_resources and sys.platform == "darwin":
            metadata["host_hardware"] = timed(phases, "host-hardware", lambda: capture(["sysctl", "-n", "hw.logicalcpu", "hw.memsize"]))
        packages = (args.source_packages or output / "SourcePackages").expanduser().resolve()
        scratch = (args.swift_scratch or output / "SwiftBuild").expanduser().resolve()
        derived = (args.derived_data or output / "DerivedData").expanduser().resolve()
        execute_lanes(run, lanes, packages, scratch, derived, args.simulator, args.boot_simulator, compilation_cache)
        verified_at = time.monotonic()
        frozen_manifest = json.loads((output / "source-manifest.json").read_text())
        verified_files = source_files(root) if args.use_checkout else [entry["path"] for entry in frozen_manifest]
        if manifest(root, verified_files) != frozen_manifest:
            raise RuntimeError("A build command changed captured source or lockfiles")
        if args.use_checkout and (capture(["git", "rev-parse", "HEAD"], repo) != metadata["commit"] or
                                  capture(["git", "status", "--porcelain=v1", "--untracked-files=all"], repo)):
            raise RuntimeError("A build command changed the dedicated checkout's Git state")
        metadata["source_verification_seconds"] = round(time.monotonic() - verified_at, 3)
        metadata["finished_utc"] = datetime.now(timezone.utc).isoformat()
        run.complete = True
        run.save()
        print("Evidence: " + str(output / "SUMMARY.md"), flush=True)
        return 0 if all(lane["status"] == "passed" for lane in run.lanes) else 1
    except Exception as error:
        (output / "BLOCKER.txt").write_text(str(error) + "\n")
        if run:
            run.lanes.append({"name": "runner", "status": "failed", "exit_code": 1, "log": str(output / "BLOCKER.txt"), "errors": [str(error)]})
            run.save()
        print("Acceptance blocked: " + str(error), file=sys.stderr)
        return 1
    finally:
        write_json(output / "phase-timings.json", phases)


if __name__ == "__main__":
    sys.exit(main())
