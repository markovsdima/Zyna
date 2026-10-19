"""Local acceptance helpers. Importing this module never accesses a device."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = 'com.app.zyna.Zyna'
NETWORK_RECOVERY = (
    'If interrupted after disconnecting, unlock the iPhone and open Settings. '
    'Restore Airplane Mode and Wi-Fi to the values in [ClosureNetwork] captured '
    'in the test log. If no capture was saved, restore your usual network settings. '
    'Keep USB connected. Relaunching Zyna does not restore the network.'
)


def nonempty(value):
    if not value.strip():
        raise argparse.ArgumentTypeError('A nonempty value is required')
    return value


def run_name(value):
    if not value or value in ('.', '..') or Path(value).name != value:
        raise argparse.ArgumentTypeError('Use a single nonempty filename component')
    return value


def fixture_marker(value):
    if not re.fullmatch(r'Zyna acceptance [A-Za-z0-9_-]{8,80}(?: [a-z][a-z0-9_-]{0,31})?', value):
        raise argparse.ArgumentTypeError('Use "Zyna acceptance UNIQUE_RUN_ID [phase]"')
    return value


def artifact(prefix, suffix):
    # with_suffix would silently replace the end of a dotted run name.
    return Path(str(prefix) + suffix)


def local_work(value):
    path = Path(value).resolve()
    if not path.is_relative_to((ROOT / '.build').resolve()):
        raise argparse.ArgumentTypeError('Keep raw logs/results under the ignored .build directory')
    return path


def reserve_run(work, name):
    work.mkdir(parents=True, exist_ok=True)
    prefix = work / run_name(name)
    suffixes = ('.log', '.xcresult', '.xctestrun', '-reserved.json', '-input.json',
                '-result.json', '-metrics.jsonl', '-deletion.jsonl', '-summary.json',
                '-sdk.json', '-installed.json', '-log-files.json', '-sdk-logs',
                '-connection.json', '-network-recovery.txt')
    if any(artifact(prefix, suffix).exists() for suffix in suffixes):
        raise ValueError('Use a new run name; existing results are never overwritten')
    with artifact(prefix, '-reserved.json').open('x') as reservation:
        reservation.write('{}\n')
    return prefix


def parse_phase(line):
    if '[AcceptancePhase]' not in line:
        return None
    match = re.search(r'\[AcceptancePhase\] (\S+) epoch=([\d.]+) status=(\{.*\})', line)
    if not match:
        raise ValueError('Malformed phase marker')
    sample = json.loads(match[3])
    if not isinstance(sample, dict):
        raise ValueError('Phase sample must be an object')
    if not isinstance(sample.get('session'), str) or not sample['session']:
        raise ValueError('Phase sample has no session identity')
    epoch = float(match[2])
    if not math.isfinite(epoch):
        raise ValueError('Invalid phase timestamp')
    return match[1], dict(epoch=epoch, sample=sample)


def load_metrics(path, warnings):
    rows = []
    if not path.exists():
        warnings.append('No metrics file was collected')
        return rows
    for number, line in enumerate(path.read_text().splitlines(), 1):
        try:
            row = json.loads(line)
            if not isinstance(row, dict) or not all(
                isinstance(row.get(key), (int, float)) and not isinstance(row[key], bool)
                and math.isfinite(row[key]) for key in ('epoch', 'elapsed', 'footprint')
            ) or not all(isinstance(row.get(key), str) and row[key] for key in ('screen', 'sdk', 'session')):
                raise ValueError('Invalid sample')
            rows.append(row)
        except (ValueError, TypeError):
            warnings.append(f'Skipped malformed metrics line {number}')
    return rows


def stream_command(command, log_path, on_line):
    """Reap the whole build group on Ctrl+C, SIGTERM or an unexpected error."""
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        with log_path.open('w', buffering=1) as log:
            with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  text=True, errors='replace', bufsize=1,
                                  start_new_session=True) as process:
                try:
                    for line in process.stdout:
                        log.write(line)
                        on_line(line)
                    return process.wait()
                except BaseException:
                    if process.poll() is None:
                        try:
                            os.killpg(process.pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait()
                    raise
    finally:
        signal.signal(signal.SIGTERM, previous)


def wired_device(data, identifier):
    devices = data.get('result', {}).get('devices', [])
    matches = [d for d in devices if identifier in (
        d.get('identifier'), d.get('hardwareProperties', {}).get('udid'))]
    if len(matches) != 1:
        raise ValueError('Cannot identify the physical device in devicectl output')
    connection = matches[0].get('connectionProperties', {})
    # Unknown/new transport values fail closed; a remembered wireless device
    # is not evidence of a currently usable USB connection.
    if (connection.get('transportType') != 'wired' or connection.get('pairingState') != 'paired'
            or connection.get('tunnelState') != 'connected'):
        raise ValueError('Offline testing requires a paired USB device; wireless/unknown transport refused')
    return connection


def require_wired_device(device, output):
    subprocess.run(['xcrun', 'devicectl', 'list', 'devices', '--timeout', '10',
                    '--json-output', str(output)], check=True, timeout=15,
                   stdout=subprocess.DEVNULL)
    return wired_device(json.loads(output.read_text()), device)


def source_identity():
    import hashlib
    return dict(
        appGitHead=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        trackedDiffSHA256=hashlib.sha256(subprocess.check_output(['git', 'diff', 'HEAD'], cwd=ROOT)).hexdigest(),
        harnessSHA256={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in Path(__file__).parent.iterdir() if p.suffix in ('.py', '.swift')})


def print_phase(line):
    try:
        phase = parse_phase(line)
    except (ValueError, TypeError):
        print('Ignoring malformed acceptance phase; raw line retained in the local log', file=sys.stderr)
        return
    if phase:
        name, record = phase
        sample = record['sample']
        print(name, 'session', sample.get('session'), 'screen', sample.get('screen'), flush=True)
