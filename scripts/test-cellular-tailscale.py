#!/usr/bin/env python3
"""Record Mac-side evidence that a cabled iPhone reaches this Mac's SSH server over cellular and Tailscale.

The cable only carries Xcode's test session. The checks fail closed if the Mac can
see the iPhone on the local network, the Tailscale route uses a non-global address,
one inside a network on the Mac's interfaces or the Mac's own public address,
sampling stops early, no SSH session arrives from the phone's tailnet address,
or the device test does not pass. A pass shows the network path; it does not show
an off-site trip, movement between cells or a Wi-Fi/cellular handoff.
"""
import argparse
import datetime
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parent.parent
TAILSCALE_APP = '/Applications/Tailscale.app/Contents/MacOS/Tailscale'
OUTCOME = re.compile(r"Test Case '-\[(?:\w+\.)?\w+ (test\w+)\]' (passed|failed|skipped)")
CAVEAT = ('This establishes the cellular/Tailscale network path for this run. It does not establish '
          'an off-site trip, movement between cells, or a Wi-Fi/cellular handoff.')


def endpoint_host(address):
    """Return the IP of a Tailscale `ip:port` or `[ipv6]:port` endpoint."""
    host = address.rsplit(':', 1)[0] if address.count(':') == 1 or address.startswith('[') else address
    return ipaddress.ip_address(host.strip('[]'))


def local_networks(ifconfig_text):
    """Networks on this Mac's interfaces, including globally routable IPv6 prefixes shared with the LAN."""
    networks = set()
    for line in ifconfig_text.splitlines():
        v4 = re.match(r'\s+inet (\S+) netmask (0x[0-9a-f]+)', line)
        v6 = re.match(r'\s+inet6 ([^\s%]+)\S* prefixlen (\d+)', line)
        if v4:
            networks.add(ipaddress.ip_interface(f'{v4[1]}/{ipaddress.IPv4Address(int(v4[2], 16))}').network)
        elif v6:
            networks.add(ipaddress.ip_interface(f'{v6[1]}/{v6[2]}').network)
    return {n for n in networks if n.prefixlen and not n.is_loopback}


def classify_path(peer, mac_public_ips, mac_networks=()):
    """Classify the peer's current WireGuard route as seen by this Mac."""
    address = peer.get('CurAddr') or ''
    if not address:
        return ('relay', 'DERP ' + peer['Relay']) if peer.get('Relay') else ('unknown', 'no route yet')
    host = endpoint_host(address)
    if not host.is_global or any(host in n for n in mac_networks):
        return 'lan', address
    if str(host) in mac_public_ips:
        return 'same-network', address
    return 'direct-public', address


def find_peer(status, name=None):
    """Find the iPhone by host name, MagicDNS name or tailnet IP, or the only online iOS peer."""
    peers = list((status.get('Peer') or {}).values())
    if name:
        wanted = name.rstrip('.').lower()
        for peer in peers:
            dns = (peer.get('DNSName') or '').rstrip('.').lower()
            names = {(peer.get('HostName') or '').lower(), dns, dns.split('.')[0]}
            if wanted in names or wanted in peer.get('TailscaleIPs', []):
                return peer
        raise SystemExit(f'No Tailscale peer matches {name!r}.')
    phones = [p for p in peers if p.get('OS') == 'iOS' and p.get('Online')]
    if len(phones) != 1:
        found = ', '.join(p.get('DNSName', '?') for p in phones) or 'none'
        raise SystemExit(f'Pass --peer: expected exactly one online iOS peer, found {found}.')
    return phones[0]


def ssh_sockets(netstat_text, peer_ips, port):
    """Established TCP connections to the local SSH port from one of the peer's tailnet IPs."""
    found = []
    for line in netstat_text.splitlines():
        fields = line.split()
        if len(fields) < 6 or not fields[0].startswith('tcp') or fields[5] != 'ESTABLISHED':
            continue
        local, remote = fields[3].rsplit('.', 1), fields[4].rsplit('.', 1)
        if local[-1] == str(port) and remote[0] in peer_ips:
            found.append(f'{fields[4]} -> {fields[3]}')
    return found


def test_outcomes(log_text):
    return {name: result for name, result in OUTCOME.findall(log_text)}


def evaluate(device, samples, outcome, manual, sampler_errors=()):
    """Return named checks, each `(passed, detail)`."""
    classes = [s['path'] for s in samples]
    bad = sorted({c for c in classes if c in ('lan', 'same-network')})
    socket_samples = [s for s in samples if s['ssh_sockets']]
    traffic = (samples[-1]['rx'] + samples[-1]['tx']) - (samples[0]['rx'] + samples[0]['tx']) if samples else 0
    checks = {
        'monitoring_complete': (not sampler_errors,
                                f'sampling stopped early: {sampler_errors[0]}' if sampler_errors
                                else 'sampled until the end of the session'),
        'device_cabled': (device.get('transportType') == 'wired',
                          f"Xcode reaches the iPhone via {device.get('transportType')!r}; 'wired' is required"),
        'path_never_local': (bool(samples) and not bad,
                             f'route classes seen: {sorted(set(classes))}' + (f'; local route {bad} fails' if bad else '')),
        'ssh_from_phone_tailnet_ip': (bool(socket_samples),
                                      f'{len(socket_samples)} of {len(samples)} samples had SSH sockets from the phone'),
        'tunnel_traffic': (traffic > 0, f'{traffic} WireGuard bytes exchanged with the phone during the run'),
    }
    if not manual:
        checks['device_test_passed'] = (outcome == 'passed', f'device test outcome: {outcome or "no result"}')
    return checks


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, **kwargs)


def tailscale_json(cli, *args):
    result = run([cli, *args])
    if result.returncode:
        raise SystemExit(f'tailscale {args[0]} failed: {result.stderr.strip()}')
    # netcheck prefixes its JSON with an unstable-format warning.
    return json.loads(result.stdout[re.search(r'^\{', result.stdout, re.M).start():])


def device_connection(udid):
    result = run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', OUT / 'devices.json'])
    if result.returncode:
        raise SystemExit('devicectl could not list devices: ' + result.stderr.strip())
    for device in json.loads((OUT / 'devices.json').read_text())['result']['devices']:
        if udid in (device.get('identifier'), device.get('hardwareProperties', {}).get('udid')):
            return device.get('connectionProperties', {})
    raise SystemExit(f'No paired device {udid}. List devices with: xcrun devicectl list devices')


def sampler(cli, peer_key, peer_ips, mac_public_ips, mac_networks, port, interval, samples, errors, stop):
    try:
        sample_until_stopped(cli, peer_key, peer_ips, mac_public_ips, mac_networks, port, interval, samples, stop)
    except (Exception, SystemExit) as error:
        # A thread's exception never reaches join(), so record it for evaluate().
        errors.append(f'{type(error).__name__}: {error}')


def sample_until_stopped(cli, peer_key, peer_ips, mac_public_ips, mac_networks, port, interval, samples, stop):
    with (OUT / 'samples.jsonl').open('w') as log:
        while True:
            peer = tailscale_json(cli, 'status', '--json')['Peer'][peer_key]
            path, endpoint = classify_path(peer, mac_public_ips, mac_networks)
            netstat = run(['netstat', '-anl', '-p', 'tcp']).stdout
            sample = {'time': datetime.datetime.now().isoformat(timespec='milliseconds'), 'path': path,
                      'endpoint': endpoint, 'rx': peer.get('RxBytes', 0), 'tx': peer.get('TxBytes', 0),
                      'ssh_sockets': ssh_sockets(netstat, peer_ips, port)}
            samples.append(sample)
            log.write(json.dumps(sample) + '\n'); log.flush()
            if stop.wait(interval):
                return


def xcodebuild(action, args, env, log_name):
    if action == 'build-for-testing':
        extra = ['-allowProvisioningUpdates', 'ENABLE_TESTABILITY=YES']
    else:
        extra = ['-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
                 '-resultBundlePath', OUT / 'tests.xcresult',
                 f'-only-testing:RemoteFilesUITests/RealServerUITests/{args.test}']
    command = ['xcodebuild', action, '-project', REPO / 'RemoteFiles.xcodeproj', '-scheme', 'RemoteFiles',
               '-configuration', 'Release', '-destination', f'id={args.device}',
               '-derivedDataPath', args.derived_data, *extra]
    print('START ' + ' '.join(map(str, command[:2])), flush=True)
    with (OUT / log_name).open('w') as log:
        process = subprocess.Popen([str(c) for c in command], cwd=REPO, env=env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for line in process.stdout:
            log.write(line)
            if 'Test Case' in line or 'REMOTEFILES_' in line or 'error:' in line:
                print(line.rstrip(), flush=True)
    return process.wait()


def main():
    global OUT
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--device', required=True, help='physical iPhone UDID (xcrun devicectl list devices)')
    parser.add_argument('--output', required=True, type=Path, help='fresh evidence directory outside the checkout')
    parser.add_argument('--peer', help="the iPhone's Tailscale name or IP; defaults to the only online iOS peer")
    parser.add_argument('--test', default='testSavedConnectionReopensRealProject', help='RealServerUITests method')
    parser.add_argument('--manual', action='store_true', help='capture while you drive the phone; stop with Return')
    parser.add_argument('--build', action='store_true', help='run build-for-testing first')
    parser.add_argument('--derived-data', type=Path, default=REPO / 'DerivedData-device')
    parser.add_argument('--port', type=int, default=22)
    parser.add_argument('--interval', type=float, default=1.0)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit('Use a fresh output directory to preserve earlier evidence.')
    args.output.mkdir(parents=True)
    OUT = args.output.resolve()
    cli = shutil.which('tailscale') or TAILSCALE_APP
    if not os.access(cli, os.X_OK):
        raise SystemExit('The Tailscale CLI was not found.')

    device = device_connection(args.device)
    status = tailscale_json(cli, 'status', '--json')
    peer = find_peer(status, args.peer)
    if not peer.get('Online'):
        raise SystemExit(f"{peer['DNSName']} is offline in Tailscale. Open Tailscale on the iPhone.")
    netcheck = tailscale_json(cli, 'netcheck', '--format=json')
    mac_public_ips = {str(endpoint_host(netcheck[k])) for k in ('GlobalV4', 'GlobalV6') if netcheck.get(k)}
    mac_networks = local_networks(run(['ifconfig']).stdout)
    peer_ips = peer['TailscaleIPs']
    ping = run([cli, 'ping', '--c', '10', peer_ips[0]])
    (OUT / 'preflight.json').write_text(json.dumps({
        'started': datetime.datetime.now().isoformat(timespec='seconds'),
        'commit': run(['git', 'rev-parse', 'HEAD'], cwd=REPO).stdout.strip(),
        'device': {'udid': args.device, 'connection': device},
        'peer': {k: peer.get(k) for k in ('DNSName', 'OS', 'TailscaleIPs', 'CurAddr', 'Relay')},
        'mac': {'tailscale_ips': status['Self']['TailscaleIPs'], 'public_ips': sorted(mac_public_ips)},
        'tailscale_ping': ping.stdout.splitlines()}, indent=2) + '\n')
    print('\n'.join(ping.stdout.splitlines()[-2:]))
    path, endpoint = classify_path(tailscale_json(cli, 'status', '--json')['Peer'][peer['PublicKey']], mac_public_ips, mac_networks)
    print(f"iPhone {peer['DNSName']} via Xcode transport {device.get('transportType')!r}; Tailscale route {path} ({endpoint})")
    if device.get('transportType') != 'wired' or path in ('lan', 'same-network'):
        raise SystemExit('The iPhone looks reachable on the local network. Turn Wi-Fi off in Settings '
                         '(not Control Center), turn off Personal Hotspot, connect the cable and retry.')

    env = dict(os.environ, TEST_RUNNER_REMOTEFILES_REAL_SERVER='1', NSUnbufferedIO='YES')
    if args.build and xcodebuild('build-for-testing', args, env, 'build.log'):
        raise SystemExit(f'build-for-testing failed; see {OUT / "build.log"}')
    sshd = subprocess.Popen(['log', 'stream', '--style', 'compact', '--predicate', 'process BEGINSWITH "sshd"'],
                            stdout=(OUT / 'sshd.log').open('w'), stderr=subprocess.STDOUT)
    samples, sampler_errors, stop = [], [], threading.Event()
    thread = threading.Thread(target=sampler, daemon=True,
                              args=(cli, peer['PublicKey'], set(peer_ips), mac_public_ips, mac_networks,
                                    args.port, args.interval, samples, sampler_errors, stop))
    thread.start()
    outcome = None
    try:
        if args.manual:
            input('Capturing. Run the manual check on the iPhone, then press Return here. ')
        else:
            status_code = xcodebuild('test-without-building', args, env, 'xcodebuild.log')
            outcome = test_outcomes((OUT / 'xcodebuild.log').read_text(errors='replace')).get(args.test)
            if status_code and outcome == 'passed':
                outcome = f'passed, but xcodebuild exited {status_code}'
    finally:
        time.sleep(args.interval)
        stop.set(); thread.join()
        sshd.terminate(); sshd.wait()

    checks = evaluate(device, samples, outcome, args.manual, sampler_errors)
    passed = all(ok for ok, _ in checks.values())
    summary = {'result': 'pass' if passed else 'fail', 'test': None if args.manual else args.test,
               'checks': {name: {'passed': ok, 'detail': detail} for name, (ok, detail) in checks.items()},
               'caveat': CAVEAT}
    (OUT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    lines = [f"# Cellular/Tailscale evidence: {summary['result'].upper()}", '',
             f"- Device test: {'manual capture' if args.manual else args.test}",
             *[f"- {'PASS' if ok else 'FAIL'} `{name}`: {detail}" for name, (ok, detail) in checks.items()],
             '', CAVEAT, '', f'Evidence: {OUT}']
    (OUT / 'summary.md').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))
    sys.exit(0 if passed else 1)


if __name__ == '__main__':
    main()
