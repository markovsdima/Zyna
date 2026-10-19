#!/usr/bin/env python3
"""Build/run paired acceptance on explicitly selected, logged-in test clients.

Choose a phase explicitly. Offline/all/followup also require a paired USB phone
and --allow-network-disruption. Network teardown cannot run after every crash;
restore Airplane Mode/Wi-Fi manually if interrupted. Raw evidence stays in .build
and may contain visible chat contents. No account data is erased or exported.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from types import SimpleNamespace
from uuid import uuid4

from run import prepare, collect_device_logs
from support import (ROOT, BUNDLE, NETWORK_RECOVERY, fixture_marker, local_work,
                     nonempty, require_wired_device, source_identity, stream_command)

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', required=True, choices=['all', 'build', 'reactions', 'offline', 'followup', 'cleanup'])
    parser.add_argument('--phone', required=True, type=nonempty, help='Physical iPhone UDID/CoreDevice UUID')
    parser.add_argument('--simulator', required=True, type=nonempty, help='Simulator UUID')
    parser.add_argument('--phone-room', required=True, type=nonempty)
    parser.add_argument('--simulator-room', required=True, type=nonempty)
    parser.add_argument('--team', type=nonempty, help='Development team for the isolated UI-test runner')
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--expected-sdk', required=True, type=nonempty, help='Expected Rust sdkGitSha()')
    parser.add_argument('--allow-network-disruption', action='store_true', help='USB-only; manual network recovery may be needed')
    parser.add_argument('--previous-marker', type=fixture_marker, help='Exact earlier fixture marker for resumption/cleanup')
    parser.add_argument('--previous-run', type=local_work, help='Earlier run directory for recovering uncollected evidence')
    parser.add_argument('--completed-odd', type=int, default=0)
    parser.add_argument('--completed-even', type=int, default=0)
    parser.add_argument('--reuse-projects-from', type=local_work,
                        help='Regenerate the copied project/scheme at this .build path; retain earlier result files')
    args = parser.parse_args()
    builds = args.phase in ('all', 'build', 'followup')
    offline = args.phase in ('all', 'offline', 'followup')
    if builds and not args.team:
        parser.error('--team is required when building the UI-test runner')
    if offline and not args.allow_network_disruption:
        parser.error('This phase includes offline testing: USB and --allow-network-disruption are required')
    if args.phase in ('followup', 'cleanup') and not args.previous_marker:
        parser.error('Resumption/cleanup requires the exact --previous-marker')
    if not 0 <= args.completed_odd <= 7 or not 0 <= args.completed_even <= 6:
        parser.error('Completed counts must be in 0...7 (odd) and 0...6 (even)')
    if (args.completed_odd or args.completed_even) and (args.phase != 'reactions' or not args.previous_marker):
        parser.error('Completed counts require --phase reactions and --previous-marker')
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid4().hex[:8]
    work = ROOT / '.build/sdk-closure' / stamp
    work.mkdir(parents=True)
    print('Results:', work, flush=True)
    (work.parent / 'latest-run.txt').write_text(str(work) + '\n')
    (work / 'input.json').write_text(json.dumps(dict(**source_identity(),
        arguments={key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()}), indent=2) + '\n')
    commands = []

    def run(command, name, check=True, env=None):
        commands.append(dict(name=name, command=list(map(str, command))))
        (work / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        print(name, flush=True)
        if command[0] == 'xcodebuild':
            code = stream_command(command, work / (name + '.log'), lambda line: None)
        else:
            with (work / (name + '.log')).open('w') as output:
                try:
                    code = subprocess.run(command, cwd=ROOT, stdout=output,
                        stderr=subprocess.STDOUT, env=env, timeout=60).returncode
                except subprocess.TimeoutExpired:
                    code = 124
        if check and code:
            raise RuntimeError(f'{name}: exit {code}; see {work}')
        return code

    if args.phase != 'build':
        run(['xcrun', 'simctl', 'get_app_container', args.simulator, BUNDLE, 'data'], 'sim-existing-account')
        run(['xcrun', 'devicectl', 'device', 'info', 'apps', '--device', args.phone,
             '--filter', f'bundleIdentifier == "{BUNDLE}"', '--json-output', str(work / 'phone-apps.json')], 'phone-existing-app')
        apps = json.loads((work / 'phone-apps.json').read_text()).get('result', {}).get('apps', [])
        if not any(app.get('bundleIdentifier') == BUNDLE for app in apps):
            parser.error('The existing logged-in phone app is required')
    if offline:
        try:
            require_wired_device(args.phone, work / 'connection-before.json')
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            parser.error(f'Offline phase refused: {error}')
        (work / 'NETWORK-RECOVERY.txt').write_text(NETWORK_RECOVERY + '\n')
        print(NETWORK_RECOVERY, flush=True)

    if args.phase == 'followup' and args.previous_run:
        # Never overwrite earlier evidence. Keep recovery in this fresh run.
        run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.phone,
             '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE,
             '--source', 'Documents/simulator-acceptance.jsonl',
             '--destination', str(work / 'previous-phone-metrics.jsonl'), '--timeout', '30'],
            'recover-previous-phone-metrics', check=False)
        previous_input = args.previous_run / 'phone-reactions-input.json'
        if previous_input.exists():
            collect_device_logs(args.phone, work, 'previous-phone', json.loads(previous_input.read_text())['startedEpoch'])

    if builds:
        for platform, room in [('device', args.phone_room), ('simulator', args.simulator_room)]:
            base = args.reuse_projects_from or work
            # Regenerate the copied scheme even when reusing its path: room/SDK
            # parameters must not silently come from a previous build.
            project = prepare(base / platform, SimpleNamespace(platform=platform, team=args.team,
                              expected_sdk=args.expected_sdk, room=room, photo_label=None))
            destination = 'generic/platform=iOS' if platform == 'device' else f'platform=iOS Simulator,id={args.simulator}'
            command = ['xcodebuild', 'build-for-testing', '-project', str(project), '-scheme', 'Acceptance',
                       '-configuration', 'Debug', '-destination', destination, '-derivedDataPath', str(args.derived_data),
                       '-clonedSourcePackagesDirPath', str(args.derived_data / 'SourcePackages'),
                       '-disableAutomaticPackageResolution', '-parallel-testing-enabled', 'NO',
                       '-only-testing:AcceptanceUITests/AcceptanceUITests/testPairAction']
            if platform == 'simulator':
                command += ['CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_ALLOWED=YES']
            run(command, 'build-' + platform)
        if args.phase == 'build':
            print('Builds complete. No test messages sent.', flush=True)
            return

    outcomes = {}
    try:
        phases = ['offline', 'reactions'] if args.phase == 'all' else ['inspect', 'cleanup', 'offline'] if args.phase == 'followup' else [args.phase]
        for phase in phases:
            marker = args.previous_marker if phase in ('inspect', 'cleanup') or (phase == 'reactions' and args.previous_marker) else 'Zyna acceptance ' + uuid4().hex + ' ' + phase
            (work / (phase + '-fixture.txt')).write_text(marker + '\n')
            clients = {}
            try:
                for which in (('sim',) if phase == 'inspect' else ('phone', 'sim')):
                    command = [sys.executable, str(HERE / 'pair.py'), '--client', which,
                               '--device', args.phone if which == 'phone' else args.simulator,
                               '--room', args.phone_room if which == 'phone' else args.simulator_room,
                               '--name', which + '-' + phase, '--action', 'closure' + phase.capitalize(),
                               '--marker', marker, '--products', str(args.derived_data / 'Build/Products'),
                               '--work', str(work), '--expected-sdk', args.expected_sdk]
                    if offline:
                        command += ['--allow-network-disruption']
                    if phase == 'reactions' and args.previous_marker:
                        command += ['--target', f'resume:{args.completed_odd}:{args.completed_even}']
                    clients[which] = subprocess.Popen(command, cwd=ROOT)
                while any(process.poll() is None for process in clients.values()):
                    if any(process.poll() not in (None, 0) for process in clients.values()):
                        break
                    time.sleep(0.25)
            finally:
                # pair.py handles SIGTERM by reaping its isolated xcodebuild group.
                for process in clients.values():
                    if process.poll() is None:
                        process.terminate()
                for process in clients.values():
                    try:
                        process.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait()
                outcomes[phase] = {which: process.returncode for which, process in clients.items()}
                (work / 'test-results.json').write_text(json.dumps(outcomes, indent=2) + '\n')
            if any(outcomes[phase].values()):
                raise RuntimeError(f'{phase} needs inspection; do not rerun with the same marker')
    finally:
        # App relaunch removes sampling. It DOES NOT restore network settings.
        if offline:
            print(NETWORK_RECOVERY, flush=True)
        flags = {key: '0' for key in ('ZYNA_ACCEPTANCE', 'ZYNA_SIM_ACCEPTANCE',
                                     'ZYNA_TIMELINE_INGEST_TRACE', 'ZYNA_DELETE_TRACE')}
        run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.phone,
             '--terminate-existing', '--environment-variables', json.dumps(flags), BUNDLE], 'phone-normal-launch', check=False)
        run(['xcrun', 'simctl', 'terminate', args.simulator, BUNDLE], 'sim-terminate', check=False)
        environment = os.environ.copy()
        environment.update({'SIMCTL_CHILD_' + key: value for key, value in flags.items()})
        run(['xcrun', 'simctl', 'launch', args.simulator, BUNDLE], 'sim-normal-launch', check=False, env=environment)
    print('Inspect both results and SDK logs; a successful script is not proof of every scenario.', flush=True)
    print('Results:', work, flush=True)


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    main()
