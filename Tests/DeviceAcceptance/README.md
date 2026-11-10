# Physical-device channel acceptance

This opt-in suite runs on a physical iPhone, in the hosted `RemoteFilesTests` target, against disposable
OpenSSH daemons the phone reaches over its own network. It covers cancellation (download, folder save,
server search), outages on the phone's own socket (idle deadline and resume, a short outage, cancelling
during an outage) and a server allowing one session channel. It is outside the default target: it needs a
provisioned Linux host, a signed device build and the phone, and missing configuration fails.

## Server

On a Linux host you administer, set up the [network fault fixture](../NetworkFaultAcceptance/README.md)
(files, manifest, host key, client key, `fault.sh`) and bind its daemon to an address the phone can reach,
such as the host's tailnet address, on port 22360. Start two more daemons from the same configuration,
with absolute paths and new `Port`/`PidFile` lines:

- port 22362 with `MaxSessions 1`, the one-channel server;
- port 22363 whose `AuthorizedKeysFile` holds only a separate control key, as
  `command="/tmp/FIXTURE/fault-gate.sh 22360 22362 DEV",restrict ssh-ed25519 ...`.

[`fault-gate.sh`](fault-gate.sh) sits beside `fault.sh`. It accepts only `PORT shape|blackhole|restore|clear`
for those two ports, with validated arguments, and runs `fault.sh` through `sudo -n`, so the control key
can toggle faults on the fixture ports and do nothing else. `DEV` is the interface the phone's traffic
uses (for example `tailscale0`). The cancellation test searches with the Linux helper under a root that
holds a `large` folder of many files containing `needle`, as in [Linux search acceptance](../LinuxSearchAcceptance/README.md).

## Run

```sh
snapshot=$(mktemp -d /private/tmp/remotefiles-device.XXXXXX)
git archive HEAD | tar -x -C "$snapshot"
cp Tests/DeviceAcceptance/DeviceChannelAcceptanceTests.swift "$snapshot/Tests/RemoteFilesCoreTests/"
cd "$snapshot" && python3 -B scripts/generate-project.py
xcodebuild build-for-testing -project RemoteFiles.xcodeproj -scheme RemoteFilesCoreCI -configuration Debug \
  -destination 'id=DEVICE' -derivedDataPath DD -allowProvisioningUpdates
TEST_RUNNER_DEVICE_HOST=ADDRESS TEST_RUNNER_DEVICE_PORT=22360 TEST_RUNNER_DEVICE_ONE_CHANNEL_PORT=22362 \
TEST_RUNNER_DEVICE_CONTROL_PORT=22363 TEST_RUNNER_DEVICE_USER=USER TEST_RUNNER_DEVICE_ROOT=/tmp/FIXTURE/files \
TEST_RUNNER_DEVICE_SEARCH_ROOT=/tmp/SEARCH_FIXTURE/files TEST_RUNNER_DEVICE_CLIENT_KEY="$(cat client)" \
TEST_RUNNER_DEVICE_CONTROL_KEY="$(cat control)" TEST_RUNNER_DEVICE_HOST_KEY="$(cat host.pub)" \
TEST_RUNNER_DEVICE_MANIFEST="$(cat manifest.sha256)" \
  xcodebuild test-without-building -xctestrun DD/Build/Products/*.xctestrun -destination 'id=DEVICE' \
  -only-testing:RemoteFilesTests/DeviceChannelAcceptanceTests -parallel-testing-enabled NO
```

Keep the phone unlocked. The keys reach the phone only in the test runner's environment and its in-memory
secret store. Afterwards clear the faults, stop the daemons by their PID files, and delete the fixture,
the keys and the control key.
