"""Local regressions for acceptance tooling; never accesses a device/server."""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from xml.etree import ElementTree

import pair
import run
from support import (ROOT, artifact, fixture_marker, print_phase, reserve_run,
                     run_name, stream_command, wired_device)

HERE = Path(__file__).resolve().parent


def sample(epoch=1, session='test-session'):
    return dict(epoch=epoch, elapsed=epoch, footprint=1024, screen='RoomsViewController',
                sdk='test-sdk', session=session, alive={'chatModel': 0})


def phase(name, row):
    return f'[AcceptancePhase] {name} epoch={row["epoch"]} status={json.dumps(row)}\n'


class ToolTests(unittest.TestCase):
    def setUp(self):
        (ROOT / '.build').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.build')
        self.work = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def analyze(self, rows, log):
        prefix = self.work / 'run.with.dots'
        artifact(prefix, '-metrics.jsonl').write_text(rows)
        artifact(prefix, '.log').write_text(log)
        result = subprocess.run([sys.executable, '-B', str(HERE / 'analyze.py'), str(prefix)],
                                capture_output=True, text=True)
        report = artifact(prefix, '-summary.json')
        return result, json.loads(report.read_text()) if report.exists() else None

    def test_dotted_names_and_interrupted_results_are_preserved(self):
        prefix = reserve_run(self.work, 'run.v1')
        self.assertEqual(artifact(prefix, '.log').name, 'run.v1.log')
        with self.assertRaises(ValueError):
            reserve_run(self.work, 'run.v1')
        artifact(self.work / 'old', '.log').write_text('interrupted before xcresult')
        with self.assertRaises(ValueError):
            reserve_run(self.work, 'old')

    def test_similar_run_names_do_not_collide(self):
        for names in [('pair-phone-1', 'pair-phone'), ('pair-phone', 'pair-phone-1')]:
            work = self.work / names[0]
            for name in names:
                prefix = reserve_run(work, name)
                artifact(prefix, '.log').write_text(name)
            for name in names:
                self.assertEqual(artifact(work / name, '.log').read_text(), name)
                with self.assertRaises(ValueError):
                    reserve_run(work, name)

    def test_device_collection_has_cli_and_host_timeouts(self):
        command = ['xcrun', 'devicectl', 'device', 'copy', 'from']
        with patch.object(run.subprocess, 'run', return_value=SimpleNamespace(returncode=0)) as call:
            self.assertTrue(run.collect_device_command(command))
            self.assertEqual(call.call_args.args[0][-2:], ['--timeout', '30'])
            self.assertEqual(call.call_args.kwargs['timeout'], 35)
        with patch.object(run.subprocess, 'run', side_effect=subprocess.TimeoutExpired(command, 35)), \
             contextlib.redirect_stderr(io.StringIO()) as warning:
            self.assertFalse(run.collect_device_command(command))
            self.assertIn('timed out', warning.getvalue())

    def test_name_and_marker_validation(self):
        for name in ('', '.', '..', '../outside', 'nested/name'):
            with self.subTest(name=name), self.assertRaises(argparse.ArgumentTypeError):
                run_name(name)
        self.assertEqual(fixture_marker('Zyna acceptance abcdef1234 reactions'), 'Zyna acceptance abcdef1234 reactions')
        for marker in ('ordinary message', 'Zyna acceptance ', 'Zyna acceptance short', 'Zyna acceptance abcdef1234\n'):
            with self.subTest(marker=marker), self.assertRaises(argparse.ArgumentTypeError):
                fixture_marker(marker)

    def test_wired_connection_is_required_and_unknown_states_fail_closed(self):
        data = {'result': {'devices': [{'identifier': 'device', 'hardwareProperties': {'udid': 'udid'},
                 'connectionProperties': {'transportType': 'wired', 'pairingState': 'paired', 'tunnelState': 'connected'}}]}}
        self.assertEqual(wired_device(data, 'device')['transportType'], 'wired')
        self.assertEqual(wired_device(data, 'udid')['transportType'], 'wired')
        with self.assertRaises(ValueError):
            wired_device(data, 'another-device')
        for key, value in [('transportType', 'localNetwork'), ('transportType', 'unknown'),
                           ('pairingState', 'unpaired'), ('tunnelState', 'disconnected')]:
            modified = json.loads(json.dumps(data))
            modified['result']['devices'][0]['connectionProperties'][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                wired_device(modified, 'device')
        with self.assertRaises(ValueError):
            wired_device({'error': 'unavailable'}, 'device')

    def test_bad_phase_json_does_not_abandon_the_process(self):
        code = "print('[AcceptancePhase] broken epoch=1 status={bad}'); print('finished'); raise SystemExit(7)"
        log = self.work / 'process.log'
        with contextlib.redirect_stderr(io.StringIO()):
            result = stream_command([sys.executable, '-c', code], log, print_phase)
        self.assertEqual(result, 7)
        self.assertIn('finished', log.read_text())

    def test_callback_failure_reaps_child_process_group(self):
        # Real local processes, not xcodebuild/devicectl. A callback error must
        # not leave the build or a process it spawned running in the background.
        stopped = self.work / 'child-stopped'
        child = "import signal,sys,os,time; from pathlib import Path; signal.signal(signal.SIGTERM,lambda *_: (Path(sys.argv[1]).write_text('stopped'),os._exit(0))); print('ready',flush=True); time.sleep(60)"
        code = ("import subprocess,sys,os,time; p=subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2]],stdout=subprocess.PIPE,text=True); "
                "p.stdout.readline(); print(os.getpid(),p.pid,flush=True); time.sleep(60)")
        pids = []
        def fail(line):
            pids.extend(map(int, line.split()))
            raise RuntimeError('simulated wrapper failure')
        with self.assertRaises(RuntimeError):
            stream_command([sys.executable, '-c', code, child, str(stopped)], self.work / 'failure.log', fail)
        self.assertEqual(len(pids), 2)
        with self.assertRaises(ProcessLookupError):
            os.kill(pids[0], 0)
        deadline = time.monotonic() + 2
        while not stopped.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(stopped.read_text(), 'stopped')

    def test_partial_cycle_and_truncated_json_produce_partial_report(self):
        row = sample()
        result, report = self.analyze(json.dumps(row) + '\n{"epoch":',
            phase('cycle1.open', row) + phase('cycle1.released', sample(10)) +
            '[AcceptancePhase] broken epoch=1 status={bad}\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report['reportStatus'], 'partial')
        cycle = report['cycles'][0]
        self.assertIn('cycle1.latestTap', cycle['missingPhases'])
        self.assertIsNone(cycle['latestTapToObservedEdgeSeconds'])
        self.assertIsNone(cycle['roomListLast10SecondsMedianMiB'])
        self.assertIsNone(cycle['settledIngestion'])
        self.assertGreaterEqual(len(report['warnings']), 3)

    def test_cycle_with_no_samples_does_not_crash(self):
        result, report = self.analyze('', phase('cycle1.open', sample()) + phase('cycle1.released', sample(10)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(report['overall'])
        self.assertEqual(report['cycles'][0]['samples'], 0)
        self.assertEqual(report['reportStatus'], 'partial')

    def test_missing_phase_session_does_not_attribute_old_metrics(self):
        result, report = self.analyze(json.dumps(sample()), '** TEST SUCCEEDED **\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(report['metricsSessionVerified'])
        self.assertEqual(report['reportStatus'], 'partial')
        self.assertIsNone(report['overall'])

    def test_wrong_or_mixed_sessions_are_rejected(self):
        for rows in ([sample(session='old')], [sample(), sample(2, 'other')]):
            with self.subTest(rows=rows):
                result, report = self.analyze('\n'.join(map(json.dumps, rows)), phase('readiness', sample()))
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(report)

    def test_complete_cycle_keeps_measurements(self):
        names = ['cycle1.open', 'cycle1.settled', 'cycle1.latestTap', 'cycle1.latestReached',
                 'cycle1.list', 'cycle1.released']
        rows = [sample(i) for i in range(1, 7)]
        result, report = self.analyze('\n'.join(map(json.dumps, rows)),
            ''.join(phase(name, row) for name, row in zip(names, rows)) + '** TEST SUCCEEDED **\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report['reportStatus'], 'complete')
        self.assertEqual(report['overall']['samples'], 6)
        self.assertEqual(report['cycles'][0]['latestTapToObservedEdgeSeconds'], 1)

    def test_sdk_summary_handles_an_empty_interrupted_capture(self):
        prefix = self.work / 'empty'
        artifact(prefix, '-metrics.jsonl').write_text('{"epoch":')
        result = subprocess.run([sys.executable, '-B', str(HERE / 'collect_sdk.py'),
                                 str(prefix), '--logs', str(self.work)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(artifact(prefix, '-sdk.json').read_text())
        self.assertIsNone(report['firstEpoch'])
        self.assertEqual(report['rebuildsFinished'], 0)
        self.assertTrue(report['warnings'])

    def test_validation_survives_python_optimization(self):
        result = subprocess.run([sys.executable, '-B', '-O', str(HERE / 'pair.py'),
            '--client', 'sim', '--device', 'fake', '--room', 'fixture', '--name', '..',
            '--action', 'inspect', '--products', str(self.work), '--expected-sdk', 'test-sdk'],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('filename component', result.stderr)

    def test_arbitrary_tap_is_not_available(self):
        result = subprocess.run([sys.executable, '-B', str(HERE / 'pair.py'),
            '--client', 'sim', '--device', 'fake', '--room', 'fixture', '--name', 'test',
            '--action', 'tap', '--products', str(self.work), '--expected-sdk', 'test-sdk'],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('invalid choice', result.stderr)

    def test_pair_plan_replaces_stale_parameters_and_offline_flag(self):
        products = self.work / 'products'; products.mkdir()
        (products / 'Acceptance_iphonesimulator.xctestrun').write_bytes(plistlib.dumps({
            'AcceptanceUITests': {'EnvironmentVariables': {'ZYNA_EXPECTED_SDK': 'old',
                'ZYNA_OFFLINE_WIRED_VERIFIED': '1'}, 'TestBundlePath': '__TESTROOT__/Fixture.xctest'}}))
        args = ['pair.py', '--client', 'sim', '--device', 'fake', '--room', 'fixture',
                '--name', 'test.v1', '--action', 'conversation', '--marker', 'Zyna acceptance abcdef1234',
                '--products', str(products), '--work', str(self.work / 'results'), '--expected-sdk', 'new-sdk']
        with patch.object(sys, 'argv', args), patch.object(pair, 'source_identity', return_value={}), \
             patch.object(pair.subprocess, 'check_output', return_value=str(self.work)), \
             patch.object(pair, 'stream_command', return_value=0) as build, \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as exit:
                pair.main()
        self.assertEqual(exit.exception.code, 0)
        plan = plistlib.loads((self.work / 'results/test.v1.xctestrun').read_bytes())['AcceptanceUITests']
        self.assertEqual(plan['EnvironmentVariables']['ZYNA_EXPECTED_SDK'], 'new-sdk')
        self.assertEqual(plan['EnvironmentVariables']['ZYNA_ACCEPTANCE_ROOM'], 'fixture')
        self.assertNotIn('ZYNA_OFFLINE_WIRED_VERIFIED', plan['EnvironmentVariables'])
        self.assertEqual(plan['TestBundlePath'], str(products) + '/Fixture.xctest')
        self.assertIn(str(self.work / 'results/test.v1.xcresult'), build.call_args.args[0])

    def test_offline_requires_explicit_permission_before_device_access(self):
        result = subprocess.run([sys.executable, '-B', str(HERE / 'pair.py'),
            '--client', 'phone', '--device', 'fake', '--room', 'fixture', '--name', 'test',
            '--action', 'closureOffline', '--marker', 'Zyna acceptance abcdef1234',
            '--products', str(self.work), '--expected-sdk', 'test-sdk'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('--allow-network-disruption', result.stderr)

    def test_reused_plan_cannot_silently_keep_an_old_sdk_or_room(self):
        products = self.work / 'Build/Products'; products.mkdir(parents=True)
        (products / 'Acceptance_iphonesimulator.xctestrun').write_bytes(plistlib.dumps({
            'AcceptanceUITests': {'EnvironmentVariables': {'ZYNA_EXPECTED_SDK': 'expected',
                                                         'ZYNA_ACCEPTANCE_ROOM': 'room'}}}))
        args = SimpleNamespace(platform='simulator', derived_data=self.work,
                               expected_sdk='expected', room='room', photo_label=None)
        run.verify_reused_plan(args)
        for key in ('expected_sdk', 'room', 'photo_label'):
            altered = SimpleNamespace(**vars(args))
            setattr(altered, key, 'changed')
            with self.subTest(key=key), self.assertRaises(ValueError):
                run.verify_reused_plan(altered)

    def test_prepared_scheme_escapes_explicit_parameters(self):
        args = SimpleNamespace(platform='simulator', expected_sdk='candidate-sha',
                               room='Fixture & "Room"', photo_label='Photo, 10:00')
        project = run.prepare(self.work, args)
        scheme = ElementTree.parse(project / 'xcshareddata/xcschemes/Acceptance.xcscheme')
        values = {item.get('key'): item.get('value') for item in scheme.findall('.//EnvironmentVariable')}
        self.assertEqual(values['ZYNA_EXPECTED_SDK'], args.expected_sdk)
        self.assertEqual(values['ZYNA_ACCEPTANCE_ROOM'], args.room)
        self.assertEqual(values['ZYNA_PHOTO_LABEL'], args.photo_label)


if __name__ == '__main__':
    unittest.main()
