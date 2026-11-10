#!/usr/bin/env python3
"""Opt-in real-server acceptance; see Tests/ServerCompatibilityAcceptance/README.md.

Run with an isolated Python containing asyncssh==2.24.1 and paramiko==5.1.0.
Servers bind only loopback, use throwaway keys and expose read-only fixture data.
No system SSH configuration, accounts or authorised keys are changed.
"""
import argparse
import asyncio
import contextlib
import hashlib
import importlib.metadata
import json
import logging
import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
SCENARIOS = ("openssh-10", "openssh-2", "openssh-1", "asyncssh-default", "paramiko-10", "paramiko-2", "paramiko-1")
PINS = {"asyncssh": "2.24.1", "paramiko": "5.1.0"}


def test_results(log, source, channel_drain):
    """Require every selected XCTest method exactly once, with no skips or stale/empty success."""
    expected = set()
    for name, body in re.findall(r"final class (\w+): XCTestCase \{(.*?)(?=\nfinal class |\nprivate final class |\Z)", source, re.S):
        if name == "ServerCompatibilityTests" or channel_drain and name == "ChannelDrainCompatibilityTests":
            expected.update((name, method) for method in re.findall(r"func (test\w+)\(", body))
    outcomes = re.findall(r"Test Case '-\[[^ ]+\.(\w+) (test\w+)\]' (passed|failed|skipped)", log)
    actual = [(name, method) for name, method, _ in outcomes]
    if not expected or set(actual) != expected or len(actual) != len(expected) or any(result != "passed" for _, _, result in outcomes):
        raise ValueError(f"XCTest inventory mismatch/failure: expected {sorted(expected)}, got {outcomes}")
    return len(expected)


def paramiko_server(directory, ready, maximum):
    import paramiko

    class ReadOnlyFiles(paramiko.SFTPServerInterface):
        def path(self, path):
            # A virtual namespace containing only this test's files, including its outside-root decoy.
            candidate = directory / path.lstrip("/")
            if not candidate.resolve().is_relative_to(directory):
                raise PermissionError("Outside fixture")
            return candidate

        def canonicalize(self, path):
            return "/" + str(self.path(path).resolve().relative_to(directory))

        def stat(self, path):
            try:
                return paramiko.SFTPAttributes.from_stat(self.path(path).stat())
            except OSError as error:
                return paramiko.SFTPServer.convert_errno(error.errno)

        def lstat(self, path):
            try:
                return paramiko.SFTPAttributes.from_stat(self.path(path).lstat())
            except OSError as error:
                return paramiko.SFTPServer.convert_errno(error.errno)

        def list_folder(self, path):
            try:
                if path.endswith("/held") and (directory / "control/hold-listing").exists():
                    (directory / "control/listing-started").touch()
                    deadline = time.monotonic() + 60
                    while (directory / "control/hold-listing").exists():
                        if time.monotonic() >= deadline:
                            return paramiko.SFTP_FAILURE
                        time.sleep(0.01)
                result = []
                for entry in self.path(path).iterdir():
                    value = paramiko.SFTPAttributes.from_stat(entry.lstat())
                    value.filename = entry.name
                    result.append(value)
                return result
            except OSError as error:
                return paramiko.SFTPServer.convert_errno(error.errno)

        def readlink(self, path):
            try:
                return os.readlink(self.path(path))
            except OSError as error:
                return paramiko.SFTPServer.convert_errno(error.errno)

        def open(self, path, flags, attr):
            if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
                return paramiko.SFTP_PERMISSION_DENIED
            try:
                handle = CappedHandle(flags)
                handle.readfile = open(self.path(path), "rb")
                return handle
            except OSError as error:
                return paramiko.SFTPServer.convert_errno(error.errno)

    class CappedHandle(paramiko.SFTPHandle):
        def read(self, offset, length):
            return super().read(offset, min(length, 4096))

        def stat(self):
            return paramiko.SFTPAttributes.from_stat(os.fstat(self.readfile.fileno()))

    authorised = paramiko.Ed25519Key.from_private_key_file(str(directory / "client"))
    host = paramiko.Ed25519Key.from_private_key_file(str(directory / "host"))

    class Server(paramiko.ServerInterface):
        def __init__(self, transport):
            self.transport = transport
            self.lock = threading.Lock()
            self.pending = 0
            self.channels = []

        def get_allowed_auths(self, username):
            return "publickey"

        def check_auth_publickey(self, username, key):
            return paramiko.AUTH_SUCCESSFUL if username == "fixture" and key == authorised else paramiko.AUTH_FAILED

        def check_channel_request(self, kind, chanid):
            with self.lock:
                active = self.pending + sum(not channel.closed for channel in self.channels)
                if kind != "session" or active >= maximum:
                    (directory / "control/channel-refused").touch()
                    print(f"CHANNEL refused active={active}", flush=True)
                    return paramiko.OPEN_FAILED_RESOURCE_SHORTAGE
                self.pending += 1
                print(f"CHANNEL accepted active={active + 1}", flush=True)
                return paramiko.OPEN_SUCCEEDED

        def check_channel_exec_request(self, channel, command):
            return False

    def connection(sock):
        with paramiko.Transport(sock) as transport:
            transport.add_server_key(host)
            transport.set_subsystem_handler("sftp", paramiko.SFTPServer, ReadOnlyFiles)
            server = Server(transport)
            try:
                transport.start_server(server=server)
                while transport.is_active():
                    channel = transport.accept(0.2)
                    if channel:
                        with server.lock:
                            server.pending -= 1
                            server.channels.append(channel)
            except (EOFError, OSError, paramiko.SSHException) as error:
                print(f"CONNECTION ended {type(error).__name__}: {error}", flush=True)

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        ready.write_text(str(listener.getsockname()[1]))
        while True:
            sock, _ = listener.accept()
            threading.Thread(target=connection, args=(sock,), daemon=True).start()


async def asyncssh_server(directory, ready):
    import asyncssh

    class ReadOnlyFiles(asyncssh.SFTPServer):
        def open(self, path, flags, attrs):
            if flags & (asyncssh.FXF_WRITE | asyncssh.FXF_APPEND | asyncssh.FXF_CREAT | asyncssh.FXF_TRUNC):
                raise asyncssh.SFTPPermissionDenied("Read-only fixture")
            return super().open(path, flags, attrs)

        def read(self, file_obj, offset, size):
            return super().read(file_obj, offset, min(size, 1024))

        def deny_write(self, *args):
            raise asyncssh.SFTPPermissionDenied("Read-only fixture")

        remove = mkdir = rmdir = rename = posix_rename = symlink = link = setstat = fsetstat = deny_write

    listener = await asyncssh.listen("127.0.0.1", 0, server_host_keys=[directory / "host"],
        authorized_client_keys=str(directory / "client.pub"), sftp_factory=lambda channel: ReadOnlyFiles(channel, chroot=os.fsencode(directory)),
        sftp_version=3, allow_scp=False)
    ready.write_text(str(listener.get_port()))
    await listener.wait_closed()


def fixture(directory):
    directory.mkdir(mode=0o700)
    for name in ("client", "host"):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(directory / name)], check=True)
    files = directory / "files"
    files.mkdir()
    (directory / "control").mkdir()
    (files / "held").mkdir()
    (files / "Unicode café 東京.txt").write_text("Unicode contents café 東京\n")
    (files / "large.txt").write_bytes(b"0123456789abcdef" * 16384)
    (directory / "outside.txt").write_text("outside secret needle\n")
    (files / "escape.txt").symlink_to("../outside.txt")
    (files / ".hidden.txt").write_text("hidden needle\n")
    for folder in range(3):
        child = files / f"folder-{folder}"
        child.mkdir()
        for index in range(4):
            (child / f"file-{folder}-{index}.txt").write_text(f"needle {folder} {index}\n" * 100)


def openssh(directory, maximum, log):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    config = directory / "sshd_config"
    username = pwd.getpwuid(os.getuid()).pw_name
    config.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {directory}/host
PidFile {directory}/sshd.pid
AuthorizedKeysFile {directory}/client.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PermitRootLogin no
AllowUsers {username}
MaxSessions {maximum}
Subsystem sftp internal-sftp
ForceCommand internal-sftp -R
LogLevel VERBOSE
""")
    if subprocess.run(["/usr/sbin/sshd", "-t", "-f", str(config), "-o", "PerSourcePenalties=no"], capture_output=True).returncode == 0:
        with config.open("a") as handle:
            handle.write("PerSourcePenalties no\n")
    process = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stdout=log, stderr=subprocess.STDOUT)
    return process, port, username


@contextlib.contextmanager
def server(name, directory, output):
    backend, limit = name.split("-")
    maximum = 0 if backend == "asyncssh" else int(limit) # AsyncSSH uses its ordinary unrestricted handler.
    ready = directory / "ready"
    with (output / (name + "-server.log")).open("w") as log:
        if backend == "openssh":
            process, port, username = openssh(directory, maximum, log)
        else:
            process = subprocess.Popen([sys.executable, "-B", str(Path(__file__).resolve()), "--serve", backend,
                "--directory", str(directory), "--ready", str(ready), "--channels", str(maximum)], stdout=log, stderr=subprocess.STDOUT)
            port, username = None, "fixture"
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"{name} exited during startup; see its server log")
                if port is None and ready.exists():
                    port = int(ready.read_text())
                if port is not None:
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                            break
                    except OSError:
                        pass
                time.sleep(0.05)
            else:
                raise RuntimeError(f"{name} did not start within 15 seconds")
            yield {"name": name, "directory": str(directory), "port": port, "username": username,
                "root": str(directory / "files") if backend == "openssh" else "/files", "channels": maximum}
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def run(args):
    for package, version in PINS.items():
        if importlib.metadata.version(package) != version:
            raise RuntimeError(f"Install the pinned fixture dependency {package}=={version}")
    output = Path(args.output).resolve() if args.output else Path(tempfile.mkdtemp(prefix="remotefiles-compatibility-", dir="/private/tmp"))
    if output.is_relative_to(ROOT):
        raise ValueError("Evidence and generated fixture keys must be outside the checkout")
    output.mkdir(parents=True, exist_ok=True)
    snapshot = output / "source"
    if snapshot.exists():
        raise ValueError("Use a fresh output directory")
    snapshot.mkdir()
    for path in ("Package.swift", "Package.resolved", "Sources", "Vendor"):
        source, target = ROOT / path, snapshot / path
        if source.is_dir():
            shutil.copytree(source, target, ignore=shutil.ignore_patterns(".build", ".git"))
        else:
            shutil.copy2(source, target)
    target = snapshot / "Tests/RemoteFilesCoreTests"
    target.mkdir(parents=True)
    shutil.copy2(ROOT / "Tests/ServerCompatibilityAcceptance/ServerCompatibilityTests.swift", target)
    command = ["swift", "test", "--package-path", str(snapshot), "--disable-automatic-resolution", "--jobs", "4"]
    report = {"head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "diff": subprocess.check_output(["git", "diff", "--stat"], cwd=ROOT, text=True),
        "sources": {str(path.relative_to(snapshot)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(snapshot.rglob("*")) if path.is_file()},
        "dependencies": {name: importlib.metadata.version(name) for name in (*PINS, "cryptography")},
        "openssh": subprocess.run(["/usr/sbin/sshd", "-V"], capture_output=True, text=True, check=True).stderr.strip(),
        "swift": subprocess.check_output(["swift", "--version"], text=True).strip(),
        "results": []}
    for index, name in enumerate(args.scenarios or SCENARIOS):
        directory = output / (name + "-fixture")
        try:
            fixture(directory)
            with server(name, directory, output) as config:
                config_path = directory / "config.json"
                config_path.write_text(json.dumps(config))
                env = dict(os.environ, REMOTEFILES_COMPATIBILITY_CONFIG=str(config_path))
                selection = "ServerCompatibilityTests|ChannelDrainCompatibilityTests" if name == "paramiko-2" else "ServerCompatibilityTests"
                test_command = command + ["--filter", selection] + (["--skip-build"] if index else [])
                print(f"Running {name}; evidence in {output}", flush=True)
                with (output / (name + "-tests.log")).open("w") as log:
                    result = subprocess.run(test_command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=1800)
                count, inventory_error = 0, None
                try:
                    count = test_results((output / (name + "-tests.log")).read_text(),
                        (target / "ServerCompatibilityTests.swift").read_text(), name == "paramiko-2")
                except ValueError as error:
                    inventory_error = str(error)
                status = result.returncode or int(inventory_error is not None)
                report["results"].append({"server": name, "exit_code": status, "passed_tests": count, "inventory_error": inventory_error})
                (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
                print(f"{name}: {'PASS' if status == 0 else 'FAIL'} ({count} tests)", flush=True)
                if index == 0 and result.returncode and "Build complete!" not in (output / (name + "-tests.log")).read_text():
                    raise RuntimeError("Build failed; no later scenario may execute stale products")
        finally:
            if directory.exists():
                shutil.rmtree(directory)
    print(f"Report: {output / 'report.json'}", flush=True)
    return int(any(row["exit_code"] for row in report["results"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output")
    parser.add_argument("--scenarios", nargs="+", choices=SCENARIOS)
    parser.add_argument("--serve", choices=("asyncssh", "paramiko"), help=argparse.SUPPRESS)
    parser.add_argument("--directory", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--ready", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--channels", type=int, default=10, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.serve:
        logging.basicConfig(level=logging.DEBUG)
    if args.serve == "asyncssh":
        asyncio.run(asyncssh_server(args.directory, args.ready))
        return 0
    if args.serve == "paramiko":
        paramiko_server(args.directory, args.ready, args.channels)
        return 0
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
