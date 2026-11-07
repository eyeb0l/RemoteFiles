#!/usr/bin/env python3
"""Reproducible RemoteFiles performance measurements. See docs/PERFORMANCE.md.

  run      Builds optimized tests, starts an isolated loopback OpenSSH fixture with a generated tree, and
           records raw samples in a JSON Lines file. Never touches system network settings.
  device   As run, for the transport scenarios on a physical iPhone over the local network: the fixture
           gets a throwaway key and a listener on the Mac's LAN address, for as long as the run lasts.
  compare  Prints median, spread and difference between two or more recorded files.

Nothing here passes or fails on a timing: shared machines are too noisy for that.
"""
import argparse, json, os, pathlib, platform, random, shlex, statistics, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
SWIFT_FLAGS = ["-c", "release", "-Xswiftc", "-enable-testing"]
WORDS = ["report", "summary", "IMG", "notes", "backup", "index", "Final", "draft", "main", "config", "data",
         "résumé", "東京", "café", "Übersicht", "log", "test", "archive", "photo", "invoice"]
SUFFIXES = ["md", "txt", "JPG", "png", "swift", "py", "json", "log", "pdf", "mp4", "tar.gz", "html", "svg", "pem", "csv"]


def mixed_folder(path, count, rng):
    """Mixed names and sizes, without allocating the bytes. Keeps OpenSSH's '.' and '..' within count."""
    path.mkdir(parents=True, exist_ok=True)
    for index in range(count):
        word, hidden = rng.choice(WORDS), "." if rng.random() < 0.03 else ""
        if rng.random() < 0.1:
            (path / f"{hidden}{word} folder {index}").mkdir()
            continue
        name = f"{hidden}{word}-{index}.{rng.choice(SUFFIXES)}"
        with open(path / name, "wb") as handle:
            handle.truncate(rng.randrange(1, 1 << 24) if rng.random() < 0.5 else 0)


def tree(path, depth, rng, branches=3):
    """A deep tree of 3^0 + ... + 3^depth folders. A few names contain the search term."""
    path.mkdir(parents=True, exist_ok=True)
    for index in range(6):
        marker = "needle-" if depth in (1, 3) and index == 0 else ""
        (path / f"{marker}{rng.choice(WORDS)}-{index}.{rng.choice(SUFFIXES)}").touch()
    if depth:
        for index in range(branches):
            tree(path / f"{rng.choice(WORDS)} {index}", depth - 1, rng, branches)


def generate_fixture(bench, include_huge):
    rng = random.Random(0x5EED)
    for count in (10, 100, 1_000, 9_900):
        mixed_folder(bench / f"d{count}", count, rng)
    if include_huge:
        mixed_folder(bench / "d100000", 100_000, rng)
    links = bench / "links"
    links.mkdir()
    for index in range(44):
        (links / f"file-{index}.txt").touch()
    for index in range(256):
        os.symlink(f"file-{index % 44}.txt", links / f"link-{index}.txt")
    tree(bench / "tree", 5, rng)
    for index in range(40):
        mixed_folder(bench / "wide" / f"folder {index}", 1_000, rng)
    (bench / "report.md").write_text("# Fixture report\n\nRead over independent OpenSSH.\n")
    (bench / "large-report.md").write_text("# Report\n" + "".join(
        f"- Measurement {i}: the remote preview reads Markdown, keeps useful content, and refreshes.\n" for i in range(1800)))
    (bench / "big-2m.bin").write_bytes(rng.randbytes(2_000_000))
    with open(bench / "big-64m.bin", "wb") as handle:
        for _ in range(64):
            handle.write(rng.randbytes(1 << 20))


def inside_fixture(args):
    """Runs under scripts/test-openssh.sh, which exported the fixture's location."""
    fixture = pathlib.Path(os.environ["REMOTEFILES_SFTP_FIXTURE"])
    started = time.time()
    bench = fixture / "files" / "bench"
    generate_fixture(bench, args.huge)
    print(f"fixture ready in {time.time() - started:.1f}s", file=sys.stderr, flush=True)
    output = pathlib.Path(args.output).resolve()
    for rtt in [int(value) for value in args.rtt.split(",")]:
        env = dict(os.environ)
        env.update(REMOTEFILES_PERFORMANCE_BENCHMARK="1", REMOTEFILES_BENCHMARK_RUNS=str(args.runs),
                   REMOTEFILES_BENCHMARK_ROOT=str(bench.resolve()),
                   REMOTEFILES_BENCHMARK_LABEL=f"{args.label}@rtt{rtt}" + (f"-{args.mbit:g}mbit" if args.mbit else ""), REMOTEFILES_BENCHMARK_OUTPUT=str(output))
        if args.only:
            env["REMOTEFILES_BENCHMARK_ONLY"] = args.only
        proxy = None
        if rtt > 0 or args.mbit:
            port = int(os.environ["REMOTEFILES_SFTP_PORT"]) + 1000
            proxy = subprocess.Popen([sys.executable, "-B", str(ROOT / "scripts/latency_proxy.py"), "--listen", str(port),
                                      "--target", os.environ["REMOTEFILES_SFTP_PORT"], "--rtt-ms", str(rtt), "--mbit", str(args.mbit)],
                                     stdout=subprocess.DEVNULL)
            env["REMOTEFILES_SFTP_PORT"] = str(port)
            time.sleep(0.5)
        try:
            subprocess.run(["swift", "test", *SWIFT_FLAGS, "--skip-build", "--filter",
                            "PerformanceBenchmarkTests/testTransport"], cwd=args.checkout, env=env, check=True,
                           stdout=subprocess.DEVNULL if not args.verbose else None)
        finally:
            if proxy:
                proxy.terminate(); proxy.wait()


def inside_device_fixture(args):
    """Runs under scripts/test-openssh.sh. The phone can't reach the fixture's files, so it gets the keys by environment."""
    fixture = pathlib.Path(os.environ["REMOTEFILES_SFTP_FIXTURE"])
    bench = fixture / "files" / "bench"
    generate_fixture(bench, False)
    key = fixture / "device-key"
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
    with open(fixture / "authorized_keys", "a") as handle:
        handle.write(key.with_suffix(".pub").read_text())
    output = pathlib.Path(args.output).resolve()
    for rtt in [int(value) for value in args.rtt.split(",")]:
        port = int(os.environ["REMOTEFILES_SFTP_PORT"]) + 1000
        proxy = subprocess.Popen([sys.executable, "-B", str(ROOT / "scripts/latency_proxy.py"), "--bind", args.address, "--listen", str(port),
                                  "--target", os.environ["REMOTEFILES_SFTP_PORT"], "--rtt-ms", str(rtt), "--mbit", str(args.mbit)],
                                 stdout=subprocess.DEVNULL)
        time.sleep(0.5)
        env = dict(os.environ)
        env.update(TEST_RUNNER_REMOTEFILES_PERFORMANCE_BENCHMARK="1", TEST_RUNNER_REMOTEFILES_BENCHMARK_RUNS=str(args.runs),
                   TEST_RUNNER_REMOTEFILES_BENCHMARK_ROOT=str(bench.resolve()),
                   TEST_RUNNER_REMOTEFILES_BENCHMARK_LABEL=f"{args.label}@device+{rtt}ms",
                   TEST_RUNNER_REMOTEFILES_BENCHMARK_PRIVATE_KEY=key.read_text(),
                   TEST_RUNNER_REMOTEFILES_BENCHMARK_HOST_KEY=(fixture / "host.pub").read_text(),
                   TEST_RUNNER_REMOTEFILES_SFTP_HOST=args.address, TEST_RUNNER_REMOTEFILES_SFTP_PORT=str(port),
                   TEST_RUNNER_REMOTEFILES_SFTP_USER=os.environ["REMOTEFILES_SFTP_USER"])
        if args.only:
            env["TEST_RUNNER_REMOTEFILES_BENCHMARK_ONLY"] = args.only
        try:
            result = subprocess.run(["xcodebuild", "test-without-building", "-xctestrun", args.xctestrun, "-destination", f"id={args.udid}",
                                     "-only-testing:RemoteFilesTests/PerformanceBenchmarkTests/testTransport", "-parallel-testing-enabled", "NO",
                                     "-collect-test-diagnostics", "never"], env=env, capture_output=True, text=True, timeout=args.timeout)
        finally:
            proxy.terminate(); proxy.wait()
        lines = [line.split("BENCHJSON ", 1)[1] for line in result.stdout.splitlines() if "BENCHJSON " in line]
        with open(output, "a") as handle:
            handle.writelines(line + "\n" for line in lines)
        print(f"rtt {rtt}: exit {result.returncode}, {len(lines)} scenarios", file=sys.stderr, flush=True)
        if result.returncode != 0:
            print("\n".join(line for line in result.stdout.splitlines() if " error:" in line or "locked" in line)[:2000], file=sys.stderr)


def device(args):
    inner = [sys.executable, "-B", str(pathlib.Path(__file__).resolve()), "inside-device-fixture", "--output", str(pathlib.Path(args.output).resolve()),
             "--label", args.label, "--runs", str(args.runs), "--rtt", args.rtt, "--mbit", str(args.mbit), "--xctestrun", args.xctestrun,
             "--udid", args.udid, "--address", args.address, "--timeout", str(args.timeout)]
    if args.only:
        inner += ["--only", args.only]
    env = dict(os.environ)
    env["REMOTEFILES_TEST_PORT"] = str(args.port)
    subprocess.run([str(ROOT / "scripts/test-openssh.sh"), *inner], env=env, check=True)


def run(args):
    args.checkout = str(pathlib.Path(args.checkout).resolve())
    if not args.skip_build:
        subprocess.run(["swift", "build", *SWIFT_FLAGS, "--build-tests"], cwd=args.checkout, check=True)
    machine = {"label": args.label, "scenario": "#environment", "unit": "", "samples": [], "machine": platform.machine(),
               "os": platform.mac_ver()[0], "git": subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=args.checkout,
                                                                 capture_output=True, text=True).stdout.strip(),
               "load": os.getloadavg()[0], "time": time.strftime("%Y-%m-%dT%H:%M:%S")}
    with open(args.output, "a") as handle:
        handle.write(json.dumps(machine) + "\n")
    if args.kind in ("local", "all"):
        env = dict(os.environ)
        env.update(REMOTEFILES_PERFORMANCE_BENCHMARK="1", REMOTEFILES_BENCHMARK_RUNS=str(args.runs), REMOTEFILES_BENCHMARK_LABEL=f"{args.label}@local",
                   REMOTEFILES_BENCHMARK_OUTPUT=str(pathlib.Path(args.output).resolve()))
        if args.only:
            env["REMOTEFILES_BENCHMARK_ONLY"] = args.only
        if args.sizes:
            env["REMOTEFILES_BENCHMARK_SIZES"] = args.sizes
        subprocess.run(["swift", "test", *SWIFT_FLAGS, "--skip-build", "--filter", "PerformanceBenchmarkTests/testLocalWork"],
                       cwd=args.checkout, env=env, check=True, stdout=subprocess.DEVNULL if not args.verbose else None)
    if args.kind in ("transport", "all"):
        inner = [sys.executable, "-B", str(pathlib.Path(__file__).resolve()), "inside-fixture", "--output", str(pathlib.Path(args.output).resolve()),
                 "--label", args.label, "--checkout", args.checkout, "--runs", str(args.runs), "--rtt", args.rtt,
                 "--mbit", str(args.mbit)]
        if args.only:
            inner += ["--only", args.only]
        if args.huge:
            inner.append("--huge")
        if args.verbose:
            inner.append("--verbose")
        env = dict(os.environ)
        env["REMOTEFILES_TEST_PORT"] = str(args.port)
        subprocess.run([str(ROOT / "scripts/test-openssh.sh"), *inner], env=env, check=True)


def load(path):
    results = {}
    for line in open(path):
        record = json.loads(line)
        if record["scenario"].startswith("#"):
            continue
        label = record["label"]
        condition = label.split("@", 1)[1] if "@" in label else ""
        key = (condition, record["scenario"])
        entry = results.setdefault(key, {"unit": record["unit"], "samples": []})
        entry["samples"].extend(record["samples"])
        if "failure" in record:
            entry["failure"] = record["failure"]
    return results


def summary(samples):
    ordered = sorted(samples)
    pick = lambda q: ordered[min(len(ordered) - 1, int(len(ordered) * q))]
    return statistics.median(ordered), pick(0.25), pick(0.75), pick(0.95)


def compare(args):
    runs = [load(path) for path in args.files]
    keys = sorted({key for run in runs for key in run})
    header = ["condition", "scenario", "unit"] + [f"{pathlib.Path(p).stem} median [IQR] p95" for p in args.files] + [
        f"{pathlib.Path(p).stem} vs first" for p in args.files[1:]]
    print(" | ".join(header))
    print(" | ".join(["---"] * len(header)))
    for key in keys:
        cells, medians = [], []
        unit = ""
        for run in runs:
            entry = run.get(key)
            if not entry or not entry["samples"]:
                cells.append("–"); medians.append(None); continue
            unit = entry["unit"]
            median, q1, q3, p95 = summary(entry["samples"])
            medians.append(median)
            failed = " (failed)" if "failure" in entry else ""
            cells.append(f"{median:.4g} [{q1:.4g}–{q3:.4g}] {p95:.4g} n={len(entry['samples'])}{failed}")
        deltas = []
        for median in medians[1:]:
            if median is None or medians[0] in (None, 0):
                deltas.append("–")
            else:
                deltas.append(f"{(median - medians[0]) / medians[0] * 100:+.0f}%")
        print(" | ".join([key[0], key[1], unit] + cells + deltas))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("run", "inside-fixture"):
        command = commands.add_parser(name)
        command.add_argument("--output", required=True)
        command.add_argument("--label", required=True)
        command.add_argument("--checkout", default=str(ROOT))
        command.add_argument("--runs", type=int, default=5)
        command.add_argument("--rtt", default="0,40,150", help="comma-separated added round trips, in ms")
        command.add_argument("--mbit", type=float, default=0, help="cap each direction; 0 is no cap")
        command.add_argument("--only", help="comma-separated scenario prefixes")
        command.add_argument("--huge", action="store_true", help="also create a 100,000-entry folder")
        command.add_argument("--verbose", action="store_true")
        if name == "run":
            command.add_argument("--kind", choices=("local", "transport", "all"), default="all")
            command.add_argument("--sizes", help="entry counts for local work, comma-separated")
            command.add_argument("--port", type=int, default=22322)
            command.add_argument("--skip-build", action="store_true")
    for name in ("device", "inside-device-fixture"):
        command = commands.add_parser(name)
        command.add_argument("--output", required=True)
        command.add_argument("--label", required=True)
        command.add_argument("--xctestrun", required=True, help="from xcodebuild build-for-testing for the device; see docs/PERFORMANCE.md")
        command.add_argument("--udid", required=True)
        command.add_argument("--address", required=True, help="this Mac's address on the phone's network")
        command.add_argument("--runs", type=int, default=3)
        command.add_argument("--rtt", default="0,40", help="round trips to add to the network's own, in ms")
        command.add_argument("--mbit", type=float, default=0)
        command.add_argument("--only", help="comma-separated scenario prefixes")
        command.add_argument("--port", type=int, default=22322)
        command.add_argument("--timeout", type=int, default=900)
    comparison = commands.add_parser("compare")
    comparison.add_argument("files", nargs="+")
    args = parser.parse_args()
    {"run": run, "inside-fixture": inside_fixture, "device": device, "inside-device-fixture": inside_device_fixture, "compare": compare}[args.command](args)


if __name__ == "__main__":
    main()
