"""Exercise the cellular/Tailscale evidence checks without a device, Tailscale or Xcode."""
import importlib.util
import ipaddress
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('cellular', Path(__file__).with_name('test-cellular-tailscale.py'))
cellular = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cellular)

PHONE = {'HostName': 'localhost', 'DNSName': 'iris-iphone.example.ts.net.', 'OS': 'iOS', 'Online': True,
         'TailscaleIPs': ['100.114.108.88', 'fd7a:115c:a1e0::1938:6c58']}


def sample(path='direct-public', rx=0, tx=0, sockets=()):
    return {'path': path, 'rx': rx, 'tx': tx, 'ssh_sockets': list(sockets)}


class ClassifyPathTests(unittest.TestCase):
    def test_lan_endpoints_are_local(self):
        for address in ('192.168.4.20:41641', '10.0.0.3:41641', '[fe80::1]:41641', '100.70.1.2:41641'):
            self.assertEqual(cellular.classify_path({'CurAddr': address}, set())[0], 'lan', address)

    def test_mac_public_address_means_the_same_network(self):
        peer = {'CurAddr': '8.8.4.4:41641'}
        self.assertEqual(cellular.classify_path(peer, {'8.8.4.4'})[0], 'same-network')
        self.assertEqual(cellular.classify_path(peer, {'9.9.9.9'})[0], 'direct-public')
        self.assertEqual(cellular.classify_path({'CurAddr': '[2606:4700::1111]:41641'}, set())[0], 'direct-public')

    def test_shared_global_ipv6_prefix_is_local(self):
        ifconfig = '\n'.join([
            'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384',
            '\tinet 127.0.0.1 netmask 0xff000000',
            '\tinet6 fe80::1%lo0 prefixlen 64 scopeid 0x1',
            'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500',
            '\tinet6 2a02:c7c:1234:5600:1c2a:3b4c:5d6e:7f80 prefixlen 64 autoconf secured',
            '\tinet 192.168.4.28 netmask 0xffffff00 broadcast 192.168.4.255',
            'utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280',
            '\tinet 100.125.79.6 --> 100.125.79.6 netmask 0xffffffff',
        ])
        networks = cellular.local_networks(ifconfig)
        self.assertIn(ipaddress.ip_network('192.168.4.0/24'), networks)
        self.assertIn(ipaddress.ip_network('2a02:c7c:1234:5600::/64'), networks)
        self.assertNotIn(ipaddress.ip_network('127.0.0.0/8'), networks)
        same_lan = {'CurAddr': '[2a02:c7c:1234:5600:aaaa:bbbb:cccc:dddd]:41641'}
        self.assertEqual(cellular.classify_path(same_lan, set(), networks)[0], 'lan')
        carrier = {'CurAddr': '[2a01:4b00:1:2::3]:41641'}
        self.assertEqual(cellular.classify_path(carrier, set(), networks)[0], 'direct-public')

    def test_relay_and_unknown_routes(self):
        self.assertEqual(cellular.classify_path({'CurAddr': '', 'Relay': 'lhr'}, set()), ('relay', 'DERP lhr'))
        self.assertEqual(cellular.classify_path({}, set())[0], 'unknown')


class FindPeerTests(unittest.TestCase):
    def status(self, *peers):
        return {'Peer': {str(i): p for i, p in enumerate(peers)}}

    def test_matches_magicdns_short_name_and_ip(self):
        status = self.status({'DNSName': 'mac.example.ts.net.', 'OS': 'macOS', 'TailscaleIPs': ['100.1.1.1']}, PHONE)
        for name in ('iris-iphone', 'iris-iphone.example.ts.net.', '100.114.108.88'):
            self.assertIs(cellular.find_peer(status, name), PHONE)
        with self.assertRaises(SystemExit):
            cellular.find_peer(status, 'missing')

    def test_default_requires_exactly_one_online_ios_peer(self):
        self.assertIs(cellular.find_peer(self.status(PHONE, dict(PHONE, Online=False))), PHONE)
        with self.assertRaises(SystemExit):
            cellular.find_peer(self.status(PHONE, dict(PHONE, DNSName='ipad.example.ts.net.')))
        with self.assertRaises(SystemExit):
            cellular.find_peer(self.status())


class OutputParsingTests(unittest.TestCase):
    def test_ssh_sockets_match_only_established_port_from_peer(self):
        netstat = '\n'.join([
            'Proto Recv-Q Send-Q  Local Address  Foreign Address  (state)',
            'tcp4  0  0  100.125.79.6.22  100.114.108.88.51234  ESTABLISHED',
            'tcp6  0  0  fd7a:115c:a1e0::1.22  fd7a:115c:a1e0::1938:6c58.51235  ESTABLISHED',
            'tcp4  0  0  100.125.79.6.22  100.114.108.88.51236  TIME_WAIT',
            'tcp4  0  0  100.125.79.6.2222  100.114.108.88.51237  ESTABLISHED',
            'tcp4  0  0  192.168.4.28.22  192.168.4.20.51238  ESTABLISHED',
            'tcp4  0  0  100.125.79.6.57848  100.114.108.88.22  ESTABLISHED',
        ])
        self.assertEqual(cellular.ssh_sockets(netstat, set(PHONE['TailscaleIPs']), 22), [
            '100.114.108.88.51234 -> 100.125.79.6.22',
            'fd7a:115c:a1e0::1938:6c58.51235 -> fd7a:115c:a1e0::1.22'])

    def test_outcomes_report_skips_as_skips(self):
        log = ("Test Case '-[RemoteFilesUITests.RealServerUITests testA]' passed (12.0 seconds).\n"
               "Test Case '-[RemoteFilesUITests.RealServerUITests testB]' skipped (0.1 seconds).\n")
        self.assertEqual(cellular.test_outcomes(log), {'testA': 'passed', 'testB': 'skipped'})


class EvaluateTests(unittest.TestCase):
    good = [sample(rx=10, tx=10), sample('relay', rx=900, tx=400, sockets=['x'])]

    def test_all_checks_pass_for_cabled_cellular_run(self):
        checks = cellular.evaluate({'transportType': 'wired'}, self.good, 'passed', manual=False)
        self.assertTrue(all(ok for ok, _ in checks.values()), checks)

    def test_each_failure_is_reported(self):
        cases = {
            'device_cabled': ({'transportType': 'localNetwork'}, self.good, 'passed'),
            'path_never_local': ({'transportType': 'wired'}, self.good + [sample('lan', 999, 999, ['x'])], 'passed'),
            'ssh_from_phone_tailnet_ip': ({'transportType': 'wired'}, [sample(rx=1), sample(rx=9)], 'passed'),
            'tunnel_traffic': ({'transportType': 'wired'}, [sample(sockets=['x'])] * 2, 'passed'),
            'device_test_passed': ({'transportType': 'wired'}, self.good, 'skipped'),
            'monitoring_complete': ({'transportType': 'wired'}, self.good, 'passed', ['SystemExit: tailscale status failed']),
        }
        for name, (device, samples, outcome, *errors) in cases.items():
            checks = cellular.evaluate(device, samples, outcome, manual=False, sampler_errors=errors[0] if errors else ())
            self.assertEqual([n for n, (ok, _) in checks.items() if not ok], [name])

    def test_manual_capture_has_no_device_test_and_no_samples_fail(self):
        self.assertNotIn('device_test_passed', cellular.evaluate({'transportType': 'wired'}, self.good, None, manual=True))
        checks = cellular.evaluate({'transportType': 'wired'}, [], None, manual=True)
        self.assertFalse(checks['path_never_local'][0])


if __name__ == '__main__':
    unittest.main()
