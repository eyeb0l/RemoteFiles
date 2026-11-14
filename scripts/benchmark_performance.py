#!/usr/bin/env python3
"""Reproducible RemoteFiles performance measurements. See docs/PERFORMANCE.md.

  run      Builds optimized tests, starts an isolated loopback OpenSSH fixture with a generated tree, and
           records raw samples in a JSON Lines file. Never touches system network settings.
  device   As run, for the transport scenarios on a physical iPhone over the local network: the fixture
           gets a throwaway key and a listener on the Mac's LAN address, for as long as the run lasts.
  server   The transport scenarios against a server you already run, such as a Linux guest for the search
           helper, alternating checkouts. Asked-for scenarios such as `assisted` and `bulk` need their folders.
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


def text_tree(path, depth, rng, level=0):
    """The shape of `tree`, 364 folders of six files each, but text of 1 to 6 KB. From the third level down
    about one file in six holds "kestrel", so the first match comes some way into the walk; none holds "zzzqq"."""
    path.mkdir(parents=True, exist_ok=True)
    for index in range(6):
        words = [rng.choice(WORDS) for _ in range(rng.randrange(150, 900))]
        if level >= 2 and rng.random() < 1 / 6:
            words.insert(rng.randrange(len(words)), "kestrel")
        (path / f"{rng.choice(WORDS)}-{index}.txt").write_text(" ".join(words) + "\n", encoding="utf-8")
    if depth:
        for index in range(3):
            text_tree(path / f"{rng.choice(WORDS)} {index}", depth - 1, rng, level + 1)


def offline_trees(path, rng):
    """Folders to save offline. `small50` is 50 small files in 10 subfolders, like the Linux guest's `docs`;
    `tiny400` is 400 tiny files in 24 folders two levels deep, more than the library's 100-file cap, so the
    benchmark drives the folder download directly; `mixed` is 40 small files and six of 0.5 to 12 MiB."""
    small = path / "small50"
    for folder in range(10):
        (small / f"part {folder}").mkdir(parents=True)
        for index in range(5):
            (small / f"part {folder}" / f"note-{index}.md").write_bytes(rng.randbytes(rng.randrange(200, 8_000)))
    tiny = path / "tiny400"
    for top in range(4):
        for inner in range(5):
            folder = tiny / f"group {top}" / f"set {inner}"
            folder.mkdir(parents=True)
            for index in range(20):
                (folder / f"item-{index}.txt").write_bytes(rng.randbytes(rng.randrange(16, 512)))
    mixed = path / "mixed"
    sizes = iter([512 << 10, 1 << 20, 2 << 20, 3 << 20, 6 << 20, 12 << 20])
    for folder in range(4):
        (mixed / f"folder {folder}").mkdir(parents=True)
        for index in range(10):
            (mixed / f"folder {folder}" / f"page-{index}.html").write_bytes(rng.randbytes(rng.randrange(1_000, 64_000)))
        for size in [next(sizes, None), next(sizes, None) if folder % 2 else None]:
            if size:
                (mixed / f"folder {folder}" / f"media-{size >> 10}k.bin").write_bytes(rng.randbytes(size))


def generate_fixture(bench, include_huge):
    rng = random.Random(0x5EED)
    offline_trees(bench / "offline", random.Random(0x0FF1))
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
    text_tree(bench / "texts", 5, random.Random(0x7E87))
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
    # The relay puts this daemon on the network and the key travels in the environment, so the key
    # gets no forwarding, terminal or agent. Commands and SFTP stay: the scenarios use both.
    with open(fixture / "authorized_keys", "a") as handle:
        handle.write("restrict " + key.with_suffix(".pub").read_text())
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


def server(args):
    """Alternates checkouts within each pass and condition, reversing the order every other pass."""
    checkouts = [pair.split("=", 1) for pair in args.checkout]
    output = str(pathlib.Path(args.output).resolve())
    for index in range(args.passes):
        for rtt in [int(value) for value in args.rtt.split(",")]:
            for label, checkout in (checkouts if index % 2 == 0 else list(reversed(checkouts))):
                port, proxy = args.port, None
                if rtt or args.mbit:
                    port = args.port + 1000
                    proxy = subprocess.Popen([sys.executable, "-B", str(ROOT / "scripts/latency_proxy.py"), "--listen", str(port), "--target",
                                              str(args.port), "--rtt-ms", str(rtt), "--mbit", str(args.mbit)], stdout=subprocess.DEVNULL)
                    time.sleep(0.5)
                env = dict(os.environ)
                env.update(REMOTEFILES_PERFORMANCE_BENCHMARK="1", REMOTEFILES_BENCHMARK_RUNS=str(args.runs), REMOTEFILES_BENCHMARK_ROOT=args.root,
                           REMOTEFILES_BENCHMARK_LABEL=f"{label}@rtt{rtt}" + (f"-{args.mbit:g}mbit" if args.mbit else ""),
                           REMOTEFILES_BENCHMARK_OUTPUT=output, REMOTEFILES_BENCHMARK_ONLY=args.only,
                           REMOTEFILES_BENCHMARK_PRIVATE_KEY=pathlib.Path(args.key).read_text(),
                           REMOTEFILES_BENCHMARK_HOST_KEY=pathlib.Path(args.host_key).read_text(),
                           REMOTEFILES_SFTP_HOST="127.0.0.1", REMOTEFILES_SFTP_PORT=str(port), REMOTEFILES_SFTP_USER=args.user)
                if args.cold_command:
                    env["REMOTEFILES_BENCHMARK_COLD_COMMAND"] = args.cold_command
                try:
                    result = subprocess.run(["swift", "test", *SWIFT_FLAGS, "--skip-build", "--filter", "PerformanceBenchmarkTests/testTransport"],
                                            cwd=str(pathlib.Path(checkout).resolve()), env=env, capture_output=True, text=True)
                finally:
                    if proxy:
                        proxy.terminate(); proxy.wait()
                print(f"pass {index} rtt {rtt} {label}: exit {result.returncode}", file=sys.stderr, flush=True)
                if result.returncode:
                    print("\n".join(line for line in result.stdout.splitlines() if " error:" in line)[:2000], file=sys.stderr)


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
    remote = commands.add_parser("server", description=server.__doc__)
    remote.add_argument("--output", required=True)
    remote.add_argument("--checkout", action="append", required=True, help="LABEL=PATH of a checkout built with `swift build -c release "
                        "-Xswiftc -enable-testing --build-tests`; repeat to alternate")
    remote.add_argument("--port", type=int, required=True, help="the server's loopback port; a delaying proxy listens 1000 above it")
    remote.add_argument("--user", required=True)
    remote.add_argument("--key", required=True, help="private key file the server accepts")
    remote.add_argument("--host-key", required=True, help="the server's public host key file")
    remote.add_argument("--root", required=True, help="the server's copy of the generated tree")
    remote.add_argument("--only", required=True, help="comma-separated scenario prefixes, such as assisted,bulk")
    remote.add_argument("--rtt", default="0,40")
    remote.add_argument("--mbit", type=float, default=0)
    remote.add_argument("--runs", type=int, default=3)
    remote.add_argument("--passes", type=int, default=2)
    remote.add_argument("--cold-command", help="run before each assisted sample, to empty the server's caches")
    comparison = commands.add_parser("compare")
    comparison.add_argument("files", nargs="+")
    args = parser.parse_args()
    {"run": run, "inside-fixture": inside_fixture, "device": device, "inside-device-fixture": inside_device_fixture, "compare": compare, "server": server}[args.command](args)


if __name__ == "__main__":
    main()
