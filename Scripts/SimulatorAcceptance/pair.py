#!/usr/bin/env python3
"""Run one scenario on an explicitly configured, logged-in test client.

Message mutations require prior authorization for this test room. Paired
conversations run concurrently on both clients with the same unique --marker.
Raw logs, UI trees and screenshots can contain chat contents; keep them local.
Offline testing requires USB plus --allow-network-disruption. Teardown is best
effort: after a crash or disconnect, restore Airplane Mode/Wi-Fi in Settings.
"""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

from run import collect_device_command, collect_device_logs
from support import (ROOT, BUNDLE, NETWORK_RECOVERY, artifact, fixture_marker,
                     local_work, nonempty, print_phase, require_wired_device,
                     reserve_run, run_name, source_identity, stream_command)

ACTIONS = ('inspect', 'input', 'sendText', 'menu', 'observe', 'profile', 'back',
           'conversation', 'photoConversation', 'photoPickerProbe', 'deletionProbe',
           'photoPosition', 'cleanupProbe', 'closureReactions', 'closureOffline',
           'closureInspect', 'closureCleanup', 'closureSettingsProbe')
READ_ONLY = {'inspect', 'input', 'profile', 'back', 'photoPickerProbe', 'closureSettingsProbe'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client', choices=['phone', 'sim'], required=True)
    parser.add_argument('--device', required=True, type=nonempty, help='Explicit device UDID or simulator UUID')
    parser.add_argument('--room', required=True, type=nonempty, help='Unique room display name on this client')
    parser.add_argument('--name', required=True, type=run_name)
    parser.add_argument('--action', required=True, choices=ACTIONS)
    parser.add_argument('--marker', type=fixture_marker, help='Shared unique fixture marker; required for message operations')
    parser.add_argument('--value', default='')
    parser.add_argument('--target', default='')
    parser.add_argument('--photo-label', type=nonempty, help='Exact accessibility label of the prepared test photo')
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--work', type=local_work, default=ROOT / '.build/paired-acceptance')
    parser.add_argument('--expected-sdk', required=True, type=nonempty, help='Expected Rust sdkGitSha()')
    parser.add_argument('--allow-network-disruption', action='store_true',
                        help='Allow the USB-only offline scenario; manual network recovery may be needed')
    args = parser.parse_args()
    if args.action not in READ_ONLY and not args.marker:
        parser.error('--marker is required for this action')
    if args.action in ('sendText', 'observe') and not args.value.startswith(args.marker + ' '):
        parser.error('--value must identify a message belonging to --marker')
    if args.action == 'menu' and not args.target.startswith(args.marker + ' '):
        parser.error('--target must identify a message belonging to --marker')
    if args.client == 'sim' and args.action in ('photoConversation', 'photoPosition') and not args.photo_label:
        parser.error('--photo-label is required to send the explicitly prepared test image')
    offline = args.client == 'phone' and args.action == 'closureOffline'
    if offline and not args.allow_network_disruption:
        parser.error('Offline testing requires --allow-network-disruption and a USB connection')
    pattern = 'Acceptance_iphoneos*.xctestrun' if args.client == 'phone' else 'Acceptance_iphonesimulator*.xctestrun'
    plans = list(args.products.glob(pattern))
    if len(plans) != 1:
        parser.error('Expected exactly one matching built .xctestrun plan in --products')
    try:
        prefix = reserve_run(args.work, args.name)
    except ValueError as error:
        parser.error(str(error))
    data = plistlib.loads(plans[0].read_bytes())

    def expand(value):
        if isinstance(value, str):
            return value.replace('__TESTROOT__', str(args.products.resolve()))
        if isinstance(value, dict):
            return {key: expand(item) for key, item in value.items()}
        if isinstance(value, list):
            return [expand(item) for item in value]
        return value

    data = expand(data)
    if 'AcceptanceUITests' not in data:
        parser.error('Unsupported test plan; rebuild with run.py')
    env = data['AcceptanceUITests'].setdefault('EnvironmentVariables', {})
    env.pop('ZYNA_OFFLINE_WIRED_VERIFIED', None)
    env.update(ZYNA_EXPECTED_SDK=args.expected_sdk, ZYNA_ACCEPTANCE_ROOM=args.room,
               ZYNA_PHOTO_LABEL=args.photo_label or '', ZYNA_FIXTURE_MARKER=args.marker or '',
               ZYNA_PAIR_ACTION=args.action, ZYNA_PAIR_VALUE=args.value, ZYNA_PAIR_TARGET=args.target)
    if args.client == 'sim':
        container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container',
                        args.device, BUNDLE, 'data'], text=True).strip())
    else:
        installed = artifact(prefix, '-installed.json')
        subprocess.run(['xcrun', 'devicectl', 'device', 'info', 'apps', '--device', args.device,
                        '--filter', f'bundleIdentifier == "{BUNDLE}"', '--json-output', str(installed)],
                       check=True, stdout=subprocess.DEVNULL)
        apps = json.loads(installed.read_text()).get('result', {}).get('apps', [])
        if not any(app.get('bundleIdentifier') == BUNDLE for app in apps):
            parser.error('Use an already installed, logged-in test app')
    if offline:
        # Check immediately before this phase, even if closure.py checked earlier.
        try:
            require_wired_device(args.device, artifact(prefix, '-connection.json'))
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            parser.error(f'Offline phase refused: {error}')
        env['ZYNA_OFFLINE_WIRED_VERIFIED'] = '1'
        artifact(prefix, '-network-recovery.txt').write_text(NETWORK_RECOVERY + '\n')
        print(NETWORK_RECOVERY, flush=True)
    plan = artifact(prefix, '.xctestrun')
    plan.write_bytes(plistlib.dumps(data))
    platform = 'iOS' if args.client == 'phone' else 'iOS Simulator'
    command = ['xcodebuild', 'test-without-building', '-xctestrun', str(plan),
               '-destination', f'platform={platform},id={args.device}', '-parallel-testing-enabled', 'NO',
               '-only-testing:AcceptanceUITests/AcceptanceUITests/testPairAction',
               '-resultBundlePath', str(artifact(prefix, '.xcresult'))]
    started = time.time()
    artifact(prefix, '-input.json').write_text(json.dumps(dict(
        **source_identity(), startedEpoch=started, client=args.client, action=args.action,
        marker=args.marker, value=args.value, target=args.target, expectedSDK=args.expected_sdk,
        sourcePlan=str(plans[0]), command=command), indent=2) + '\n')

    def progress(line):
        if '[PairState]' in line or '[PairMatches]' in line or '[Closure' in line or 'error: -[' in line:
            print(line.rstrip(), flush=True)
        print_phase(line)

    print(f'{args.client}: {args.action}', flush=True)
    try:
        returncode = stream_command(command, artifact(prefix, '.log'), progress)
    except KeyboardInterrupt:
        returncode = 130
    finally:
        if offline:
            print(NETWORK_RECOVERY, flush=True)
    # Preserve the process outcome even if later collection is interrupted.
    artifact(prefix, '-result.json').write_text(json.dumps(dict(
        returncode=returncode, startedEpoch=started, finishedEpoch=time.time()), indent=2) + '\n')
    if args.client == 'sim':
        # Installation can replace the data-container path; resolve it again.
        container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container',
                         args.device, BUNDLE, 'data'], text=True).strip())
        for source_name, suffix in [('simulator-acceptance', '-metrics'), ('deletion-trace', '-deletion')]:
            if source_name == 'deletion-trace' and args.action not in ('deletionProbe', 'photoPosition'):
                continue
            source = container / f'Documents/{source_name}.jsonl'
            if source.exists():
                shutil.copy2(source, artifact(prefix, suffix + '.jsonl'))
    else:
        collect_device_command(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                        '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE,
                        '--source', 'Documents/simulator-acceptance.jsonl',
                        '--destination', str(artifact(prefix, '-metrics.jsonl'))])
        collect_device_logs(args.device, args.work, args.name, started)
    print('Result:', returncode, 'Log:', artifact(prefix, '.log'), flush=True)
    raise SystemExit(returncode)


if __name__ == '__main__':
    main()
