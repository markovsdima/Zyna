# Acceptance on logged-in devices

These opt-in tools exercise Zyna through XCTest using existing test accounts.
They build a copy of the Xcode project under `.build`; the main project gains no
UI-test target. They do not erase a device, log out, copy credentials or export
the account database. Opening a chat still triggers normal sync/read receipts.

Message scenarios send, edit, react to and delete real messages. Use an agreed
test room and obtain authorization for those actions. The room must have a unique
display name on each client. Only messages belonging to the supplied fixture
marker are selected for modification. Existing drafts must be left intact.

## Configuration

No device IDs, development team, room names or DerivedData paths are built in.
Supply them on the command line. For convenience, keep shell variables in a
local file under the ignored `.build` directory. Do not commit that file.

The examples use these locally supplied values:

- `SIMULATOR_ID` / `PHONE_ID`: simulator UUID and physical iPhone UDID or CoreDevice UUID.
- `SIMULATOR_ROOM` / `PHONE_ROOM`: the shared test chat's display name on each client.
- `DERIVED_DATA`: the prepared Xcode DerivedData directory.
- `DEVELOPMENT_TEAM`: the team signing the isolated UI-test runner.
- `SDK_SHA`: the expected Rust `sdkGitSha()` from the SDK release/build manifest.

`--expected-sdk` is required. `Package.resolved` identifies the Swift package
revision, which is not the Rust runtime identity. Assertions check the loaded
library before navigating or modifying messages.

```sh
python3 Scripts/SimulatorAcceptance/run.py \
  --device "$SIMULATOR_ID" --room "$SIMULATOR_ROOM" \
  --name readiness-1 --test testLaunchMetrics \
  --derived-data "$DERIVED_DATA" --expected-sdk "$SDK_SHA"
```

For iPhone, add `--platform device --team "$DEVELOPMENT_TEAM"` and use the phone
ID and room. The phone must be paired, unlocked and trusted for UI automation.
`--allow-provisioning-updates` lets Xcode obtain profiles for the new runner.
`--build-only` prepares app/runner products without installing or launching on
the phone. Existing app and extension signing settings are preserved.

`--without-building` reuses previously built products. Rebuild after changing
sources or room/SDK parameters; the original test plan carries their environment.
Do not run simultaneous builds against shared DerivedData.

`closure.py --reuse-projects-from` preserves the earlier project path for
incremental builds, but regenerates its copied project and scheme with the current
parameters. Result files are preserved; the earlier directory as a whole changes.
Omit this option when that directory must remain unchanged.

Run names are single filename components, including dots if desired. Each name
is reserved before use. Existing evidence, including an interrupted run's logs,
is never overwritten; choose another name for retries.

## Navigation and queue lifetime

Start with `testLaunchMetrics`, then `testControlsProbe`. The large fixture needs
more than 1,000 catalog media records; these are not arbitrary-room tests.

`testRepeatedAttachments` performs two traversals with different grid scales,
reverses direction, switches tabs and returns to the chat and room list. It waits
for history completion and empty queues *inside the chat* before exiting. If
background history is still progressing, that wait can time out without proving
a stuck worker.

`testExitQueueLifecycle` leaves during observed work, repeats quick chat/profile
switches and waits in the room list in one app process. It checks observed owner
release, including final ingestion metrics that can outlive the batcher.
`busyNotObserved` means pending work was not sampled before exit; do not call that
a confirmed busy exit. `testBusyExitObservation` separately looks for a large
backlog; read its phase outcome even when XCTest succeeds.

Summarize an existing run without accessing a device:

```sh
python3 Scripts/SimulatorAcceptance/analyze.py .build/simulator-acceptance/readiness-1
python3 Scripts/SimulatorAcceptance/collect_sdk.py \
  .build/simulator-acceptance/readiness-1 --logs /path/to/local/app-logs
```

Interrupted logs produce a partial report with unavailable measurements marked
`null`. Broken JSON lines are reported and skipped. Missing session evidence
prevents attribution; mismatched or mixed sessions are rejected. A partial report
or successful summary generation does not turn a failed XCTest into a pass.

## Paired message scenarios

Build both platforms first with the same sources. `closure.py --phase build`
accepts `--phone`, `--simulator`, `--phone-room`, `--simulator-room`, `--team`,
`--derived-data` and `--expected-sdk`. It builds sequentially to avoid contention.

For a continuous text or photo conversation, run `pair.py` concurrently on both
clients, using different result names and **the same fresh marker**:

```sh
MARKER="Zyna acceptance $(uuidgen)"
python3 Scripts/SimulatorAcceptance/pair.py \
  --client phone --device "$PHONE_ID" --room "$PHONE_ROOM" \
  --name pair-phone-1 --action conversation --marker "$MARKER" \
  --products "$DERIVED_DATA/Build/Products" --expected-sdk "$SDK_SHA"
# In another terminal, with the same MARKER:
python3 Scripts/SimulatorAcceptance/pair.py \
  --client sim --device "$SIMULATOR_ID" --room "$SIMULATOR_ROOM" \
  --name pair-sim-1 --action conversation --marker "$MARKER" \
  --products "$DERIVED_DATA/Build/Products" --expected-sdk "$SDK_SHA"
```

Markers have the form `Zyna acceptance UNIQUE_RUN_ID [phase]`; the ID contains
8–80 letters, digits, hyphens or underscores. Preserve the exact marker for
explicit resumption/cleanup. A new attempt should normally use a new marker.
The generic unrestricted `tap` action is intentionally unavailable.

For `photoConversation` or simulator `photoPosition`, first import and visually
verify a harmless test image. Run `photoPickerProbe` to inspect its selector;
pass its exact accessibility label with `--photo-label`. The label depends on
Photos and locale, so it is not hardcoded. The receiver does not need that asset.
The picker's Done button supports Russian and English labels. The preview's Send
button is selected by `attachmentPreview.send`, independently of its translation
or the composer's Send button underneath the modal preview. Other picker locales
may require selector changes; a configurable photo label does not localize the UI test.
`run.py --test testPhotoPreviewSendSelector --photo-label '…'` checks this selector
with a real preview and a temporary caption, then discards both without sending.

`closure.py --phase reactions` coordinates the rapid-toggle scenario on both
clients. Supply the same device/room/path/SDK arguments as for `--phase build`.
`--phase cleanup --previous-marker '…'` removes only that fixture. Resumption of
an interrupted reaction scenario also requires verified `--completed-odd` and
`--completed-even` counts; do not guess them. `--previous-run` lets `followup`
recover remaining evidence into the new directory, preserving older files.

Photo caption tests use the DEBUG caption editor and the actual SDK edit path.
Text/reaction/deletion tests use Zyna's ordinary outbox. They do not independently
validate every SDK pending-send or focused-timeline API. Inspect both clients'
results and `[PairDeletion]` observations; some diagnostic scenarios intentionally
record transient findings while continuing cleanup.

## Offline testing and recovery

Offline execution is explicit: `--phase offline`, `all` or `followup` additionally
requires `--allow-network-disruption`. It is not part of a default run.
Both the coordinator and the phone's `pair.py` wrapper check `devicectl` for a
paired wired connection. Unknown, unavailable and network-only connections are
refused. The UI test requires the wrapper's verified-offline flag before touching
Settings. Keep the USB cable connected throughout the run.

Before changing either switch, XCTest records the original Airplane Mode and
Wi-Fi values in `[ClosureNetwork] captured ...` and a `network-before` attachment.
Teardown restores those values during normal completion and handled test failure.
**USB does not guarantee teardown after a crash, force quit, cable removal or
interrupted runner.** Restarting Zyna does not restore the network.

If interrupted after disconnecting:

1. Unlock the iPhone and open **Settings**.
2. Set **Airplane Mode** and **Wi-Fi** to the captured original values (`0` means
   off, `1` means on). If the capture was not saved, restore your usual settings.
3. Check connectivity before resuming. Keep the failed run's logs and use a fresh
   run name; inspect any remaining fixture before retrying or deleting it.

The coordinator writes `NETWORK-RECOVERY.txt` in its run directory. The phone
wrapper writes `<name>-network-recovery.txt` beside its log. There is no guarantee
of remote recovery once the test runner or its connection is lost.

## Evidence and limits

The opt-in DEBUG app probe samples once per second: footprint, CPU time, thermal
state, navigation, row counts, queues and weakly observed owners. Probe JSONL has
no message content, account IDs or event IDs. **Raw SDK logs, XCTest logs,
accessibility trees, screenshots and xcresult bundles may contain chat content
and identifiers.** Keep them local under `.build`; sanitize any shared extracts.
Do not publish the entire results directory.

The runner stores SDK identity, source fingerprints, phases and process outcomes.
Each device metrics/log collection command has a 30-second CLI timeout and a
35-second host deadline. Failed collection retains earlier evidence and prints a
warning; summary availability must be checked separately from the XCTest result.
A reused binary may predate current source hashes: `--without-building` is not a
proof of binary/source identity. Swift Debug with Rust release and a 1 Hz sampler
is not an optimized performance benchmark. Brief peaks can be missed. CPU time
and battery percentage do not measure exact energy consumption.

`rawItems` counts item occurrences in retained callback arrays, not unique
messages. The prepared-payload limit does not bound raw SDK backlog or total RAM.
Zero weak counts establish release only for observed owners, not global caches.
Latest-button timings include XCTest/polling overhead. A run with no SDK lag does
not exercise rebuild recovery. Simulator measurements do not predict iPhone
memory pressure, frame rate or energy use.

The Python wrapper stops and reaps its xcodebuild process group on interruption;
malformed phase JSON alone does not abandon a running build. Network restoration
still has the limits described above. For local helper regression checks:

```sh
python3 -B -m unittest discover -s Scripts/SimulatorAcceptance -p 'test_*.py'
```
