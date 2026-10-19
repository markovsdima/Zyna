#!/usr/bin/env python3
"""Extract SDK timeline diagnostics for one completed acceptance run, without spans."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re

from support import load_metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path, help='Run prefix, without .log')
    parser.add_argument('--logs', type=Path, required=True)
    args = parser.parse_args()
    prefix = str(args.run)
    warnings = []
    samples = load_metrics(Path(prefix + '-metrics.jsonl'), warnings)
    if len({sample['session'] for sample in samples}) > 1:
        parser.error('Refusing mixed-session metrics')
    start, end = (samples[0]['epoch'], samples[-1]['epoch']) if samples else (None, None)
    lines = []
    sources = []
    for path in sorted(args.logs.glob('zyna-app.*.log')):
        used = False
        for line in path.open(errors='replace'):
            if not any(target in line for target in (
                'matrix_sdk_ui::timeline::cache_lag:',
                'matrix_sdk::event_cache::focused_snapshot:')):
                continue
            try:
                epoch = datetime.fromisoformat(line.split()[0].replace('Z', '+00:00')).timestamp()
            except ValueError:
                continue
            if start is not None and start <= epoch <= end:
                # Span fields can include room IDs. These aggregated messages
                # contain only timeline IDs, counts, flags and timing.
                lines.append(line.split(' | ')[0].rstrip())
                used = True
        if used:
            sources.append(path.name)
    rebuilds = [{key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}
        for line in lines if 'Timeline cache rebuild finished ' in line]
    receipt_work = [{key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}
        for line in lines if 'Timeline cache rebuild receipt work ' in line]
    receipt_reconciliation = [{
        'timestamp': line.split()[0],
        **{key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}}
        for line in lines if 'Timeline recovery receipt reconciliation ' in line]
    focused_snapshots = [{
        'timestamp': line.split()[0],
        **{key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}}
        for line in lines if 'Focused snapshot acquired ' in line]
    # Sum batch deltas only: *_total already accumulates within a timeline's
    # recovery generation, and a new rebuild resets those cumulative counters.
    receipt_sums = {field: sum(row.get(field, 0) for row in receipt_reconciliation)
        for field in ('receipt_store_reads', 'receipt_store_matched',
            'receipt_store_differed', 'receipt_store_missing', 'receipt_store_read_us')}
    result = dict(firstEpoch=start, lastEpoch=end, sources=sources, warnings=warnings,
        timelinesCreated=sum('Timeline created ' in line for line in lines),
        lags=sum('Timeline cache lag ' in line for line in lines),
        rebuildsStarted=sum('Timeline cache rebuild started ' in line for line in lines),
        rebuildsFinished=sum('Timeline cache rebuild finished ' in line for line in lines),
        rebuilds=rebuilds, receiptWork=receipt_work,
        receiptReconciliation=receipt_reconciliation,
        receiptReconciliationBatchSums=receipt_sums,
        focusedSnapshots=focused_snapshots, lines=lines)
    Path(prefix + '-sdk.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: value for key, value in result.items() if key != 'lines'}, indent=2))


if __name__ == '__main__':
    main()
