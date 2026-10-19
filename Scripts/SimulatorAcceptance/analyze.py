#!/usr/bin/env python3
"""Summarize the local JSONL probe and phase markers from one UI acceptance run."""
import argparse
import json
from pathlib import Path
import re
import statistics

from support import load_metrics, parse_phase


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path, help='Run prefix, without .log')
    args = parser.parse_args()
    prefix = str(args.run)
    warnings = []
    rows = load_metrics(Path(prefix + '-metrics.jsonl'), warnings)
    log_path = Path(prefix + '.log')
    log = log_path.read_text(errors='replace') if log_path.exists() else ''
    phases = {}
    for number, line in enumerate(log.splitlines(), 1):
        try:
            phase = parse_phase(line)
            if phase:
                phases[phase[0]] = phase[1]
        except (ValueError, TypeError):
            warnings.append(f'Skipped malformed phase at log line {number}')
    sessions = {row['session'] for row in rows}
    phase_sessions = {phase['sample']['session'] for phase in phases.values() if 'session' in phase['sample']}
    if len(sessions) > 1 or len(phase_sessions) > 1 or (sessions and phase_sessions and sessions != phase_sessions):
        parser.error('Metrics do not match the test phases; refusing stale or mixed samples')
    verified = bool(sessions) and sessions == phase_sessions
    if rows and not verified:
        warnings.append('No matching session in phase markers; metrics are not attributed to this run')
        rows = []
    if not rows:
        warnings.append('No attributable samples; unavailable measurements are null')

    def window(start, end):
        if start is None or end is None:
            return []
        return [row for row in rows if start <= row['epoch'] <= end]

    def stats(samples):
        if not samples:
            return None
        queues = [row['ingestion'] for row in samples if 'ingestion' in row]
        all_queues = queues + [queue for row in samples for queue in row.get('retainedIngestionQueues', [])]
        cpu = [row['cpuPercent'] for row in samples if 'cpuPercent' in row]
        cpu_span = [row for row in samples if 'cpuSeconds' in row]
        cpu_seconds = (cpu_span[-1]['cpuSeconds'] - cpu_span[0]['cpuSeconds']) if len(cpu_span) > 1 else None
        wall_seconds = (cpu_span[-1]['elapsed'] - cpu_span[0]['elapsed']) if len(cpu_span) > 1 else 0
        return dict(samples=len(samples), peakMiB=max(row['footprint'] for row in samples) / 2**20,
            cpuSeconds=cpu_seconds,
            cpuMeanPercent=(100 * cpu_seconds / wall_seconds) if wall_seconds else None,
            cpuPeakSamplePercent=max(cpu, default=None),
            cpuP95SamplePercent=sorted(cpu)[min(len(cpu)-1, int(len(cpu)*0.95))] if cpu else None,
            thermalStates=sorted({row['thermalState'] for row in samples if 'thermalState' in row}),
            lowPowerModes=sorted({row['lowPowerMode'] for row in samples if 'lowPowerMode' in row}),
            lastMiB=samples[-1]['footprint'] / 2**20,
            profilePeakMiB=max((row['footprint'] for row in samples if row['screen'] == 'RoomProfileViewController'), default=0) / 2**20,
            chatPeakMiB=max((row['footprint'] for row in samples if row['screen'] == 'ChatViewController'), default=0) / 2**20,
            longestSampleIntervalSeconds=max((b['elapsed'] - a['elapsed'] for a, b in zip(samples, samples[1:])), default=0),
            maxChatRows=max((row.get('chatRows', 0) for row in samples)),
            maxMediaTiles=max((row.get('mediaTiles', 0) for row in samples)),
            maxMediaCachedItems=max((row.get('mediaCachedItems', 0) for row in samples)),
            columns=sorted({row['mediaColumns'] for row in samples if 'mediaColumns' in row}),
            mediaCounts=sorted({row['mediaCount'] for row in samples if 'mediaCount' in row}),
            maxIndexErrors=max((row.get('attachmentIndexErrors', 0) for row in samples)),
            maxObservedFailedBatches=max((queue.get('failedBatches', 0) for queue in all_queues), default=0),
            ingestionHighWater={key: max((row[key] for row in all_queues if key in row), default=None) for key in
                ['peakRawItems', 'peakMappedEvents', 'peakMappedBytes', 'failedBatches']})

    def phase_epoch(name):
        return phases.get(name, {}).get('epoch')

    def phase_sample(name):
        return phases.get(name, {}).get('sample', {})

    succeeded = bool(re.search(r'\*\* TEST (?:EXECUTE )?SUCCEEDED \*\*', log))
    result = dict(testSucceeded=succeeded, metricsSessionVerified=verified, warnings=warnings,
        sdk=sorted({row['sdk'] for row in rows}),
        platforms=sorted({row['platform'] for row in rows if 'platform' in row}),
        buildConfigurations=sorted({row['buildConfiguration'] for row in rows if 'buildConfiguration' in row}),
        firstEpoch=rows[0]['epoch'] if rows else None, lastEpoch=rows[-1]['epoch'] if rows else None,
        durationSeconds=rows[-1]['elapsed'] - rows[0]['elapsed'] if rows else None,
        overall=stats(rows), phases=phases, cycles=[])
    for cycle in (1, 2):
        key = f'cycle{cycle}'
        if not any(name.startswith(key + '.') for name in phases):
            continue
        required = ('.open', '.list', '.released', '.latestTap', '.latestReached', '.settled')
        missing = [key + suffix for suffix in required if key + suffix not in phases]
        if missing:
            warnings.append(f'{key}: missing phases: ' + ', '.join(missing))
        start, end = phase_epoch(key + '.open'), phase_epoch(key + '.released')
        summary = stats(window(start, end)) or dict(samples=0)
        list_epoch = phase_epoch(key + '.list')
        tail = window(max(end - 10, list_epoch), end) if end is not None and list_epoch is not None else []
        latest_start, latest_end = phase_epoch(key + '.latestTap'), phase_epoch(key + '.latestReached')
        summary.update(cycle=cycle, missingPhases=missing,
            releasedAlive=phase_sample(key + '.released').get('alive'),
            drainedBeforeExit=key + '.drained' in phases,
            retainedModelQueues=phase_sample(key + '.released').get('retainedModelQueues'),
            roomListLast10SecondsMedianMiB=statistics.median(row['footprint'] for row in tail) / 2**20 if tail else None,
            roomListLast10Seconds=stats(tail),
            latestTapToObservedEdgeSeconds=latest_end - latest_start if latest_start is not None and latest_end is not None else None,
            settledIngestion=phase_sample(key + '.settled').get('ingestion'),
            confirmedEdges=[name for name in (key + '.older.edge', key + '.newer.edge') if name in phases])
        result['cycles'].append(summary)
    if 'busy.list' in phases:
        start = phase_epoch('busy.list')
        tail = window(start, rows[-1]['epoch'] if rows else None)
        release = {}
        for kind in ('chat', 'profile', 'chatModel', 'chatTimeline', 'ingestionBatcher', 'ingestionMetrics'):
            gone = next((row for row in tail if row.get('alive', {}).get(kind) == 0), None)
            release[kind] = gone['epoch'] - start if gone else None
        result['busyExit'] = dict(backlogReproduced='busy.confirmed' in phases,
            releaseConfirmed='busy.released' in phases,
            observedSeconds=tail[-1]['epoch'] - start if tail else None,
            firstObservedAbsenceSeconds=release,
            afterExit=stats(tail), finalAlive=tail[-1].get('alive') if tail else None,
            finalQueues=tail[-1].get('retainedIngestionQueues') if tail else None)
    result['segments'] = {}
    for cycle in (1, 2):
        key = f'cycle{cycle}'
        for title, first, last in (
            ('profile', '.profile', '.chat'), ('settle', '.settle', '.settled'),
            ('roomList', '.list', '.released')):
            if key + first in phases and key + last in phases:
                result['segments'][key + '.' + title] = stats(window(
                    phases[key + first]['epoch'], phases[key + last]['epoch']))
    result['reportStatus'] = 'complete' if succeeded and not warnings else 'partial'
    Path(prefix + '-summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: value for key, value in result.items() if key != 'phases'}, indent=2))


if __name__ == '__main__':
    main()
