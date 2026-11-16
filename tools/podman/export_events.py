#!/usr/bin/env python3
"""Export first observed triggers and censoring for a predeclared bug cohort.

No median is computed here. Keep bug, target, fuzzer and trial identifiers when
performing survival analysis; observations within a campaign are not independent.
"""
import argparse
import csv
from pathlib import Path


def campaign_rows(path, bugs):
    if (path / 'container-exit-code').read_text().strip() != '0':
        raise ValueError(f'{path}: failed campaign; do not treat as censored success')
    if (path / 'fuzzer-exit-code').read_text().strip() != '124':
        raise ValueError(f'{path}: campaign did not exhaust its budget')
    end = int((path / 'elapsed-seconds').read_text())
    cutoff_file = path / 'observation-end-seconds'
    observed = int(cutoff_file.read_text()) if cutoff_file.exists() else end
    config = {}
    for line in (path / 'campaign.txt').read_text().splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            config[key] = value
    first = {}
    samples = sorted((int(p.name), p) for p in (path / 'monitor').iterdir()
                     if p.name.isdigit())
    if not samples or samples[-1][0] != observed or not 0 <= observed <= end:
        raise ValueError(f'{path}: missing final monitor sample')
    if end - observed > int(config.get('poll', '5')) + 2:
        raise ValueError(f'{path}: monitor observations ended too early')
    for timestamp, sample in samples:
        with sample.open(newline='') as stream:
            data = list(csv.DictReader(stream))
        if len(data) != 1:
            raise ValueError(f'{sample}: invalid monitor CSV')
        for bug in bugs:
            if int(data[0].get(bug + '_T', '0') or '0') > 0:
                first.setdefault(bug, timestamp)
    for bug in bugs:
        yield [str(path), config['target'], config['program'], config['fuzzer'],
               bug, first.get(bug, observed), int(bug in first), end, observed]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bugs', required=True, type=Path,
                        help='Validated cohort: one bug ID per line, # comments allowed')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('campaigns', nargs='+', type=Path,
                        help='Completed trials of ONE target/program')
    args = parser.parse_args()
    bugs = [line.split('#', 1)[0].strip() for line in args.bugs.read_text().splitlines()]
    bugs = sorted(set(filter(None, bugs)))
    if not bugs:
        parser.error('Empty bug cohort')
    rows = [row for path in args.campaigns for row in campaign_rows(path, bugs)]
    if len({(row[1], row[2]) for row in rows}) != 1:
        parser.error('Export one target/program at a time with its own validated cohort')
    # Exclusive create: do not silently overwrite an analysis artifact.
    with args.output.open('x', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['campaign', 'target', 'program', 'fuzzer', 'bug',
                         'time_seconds', 'triggered', 'observed_run_seconds',
                         'observation_end_seconds'])
        writer.writerows(rows)


if __name__ == '__main__':
    main()
