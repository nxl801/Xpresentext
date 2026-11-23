"""Replay finalized English ASR segments through the installed Xpresentext helper."""
import argparse
from collections import Counter
import json
from pathlib import Path
import statistics
import subprocess
import time

from evaluate import count_results, dataset, stats


def receive(proc):
    line = proc.stdout.readline()
    if not line:
        raise RuntimeError('No response from packaged helper')
    message = json.loads(line)
    if message['type'] in ('error', 'missing'):
        raise RuntimeError(message)
    return message


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--set', default='integration-audio')
    parser.add_argument('--record', type=Path)
    parser.add_argument('--adjacent', action='store_true', help='Include next slide just as in the presenter')
    args = parser.parse_args()
    pages = dataset(args.set)
    helper = args.app.resolve() / 'Contents/Helpers/MurmuryPresenter.app/Contents/MacOS/MurmuryPresenter'
    rows, counts = [], Counter()
    with subprocess.Popen([helper, 'coverage', 'local'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as proc:
        start = time.perf_counter()
        while receive(proc)['type'] != 'ready':
            pass
        cold = time.perf_counter() - start
        for i, page in enumerate(pages):
            candidates = pages[i:i+(2 if args.adjacent else 1)]
            for j, (text, spoken) in enumerate(page['cases']):
                job = {'id': f'{i}/{j}', 'text': text,
                       'pages': [{'title': p['slide'], 'points': p['points']} for p in candidates]}
                start = time.perf_counter()
                proc.stdin.write(json.dumps(job) + '\n')
                proc.stdin.flush()
                result = receive(proc)
                elapsed = time.perf_counter() - start
                assert result['type'] == 'result' and result['id'] == job['id'], result
                scores = result['scores']
                counts.update(count_results(scores[0], spoken))
                rows.append({'id': job['id'], 'slide': page['slide'], 'transcript': text,
                             'expected': spoken, 'scores': scores, 'seconds': round(elapsed, 3)})
                print(job['id'], scores, f'{elapsed:.2f}s', flush=True)
        proc.stdin.close()
        if proc.wait() != 0:
            raise RuntimeError('Failed to finish local replay')
    times = [r['seconds'] for r in rows]
    result = {'set': args.set, 'adjacent': args.adjacent, 'cold_seconds': round(cold, 3),
              'counts': dict(counts), 'median_seconds': statistics.median(times),
              'p95_seconds': round(statistics.quantiles(times, n=100, method='inclusive')[94], 3), 'rows': rows}
    print(stats(counts), 'median', result['median_seconds'], 'p95', result['p95_seconds'], flush=True)
    if args.record:
        args.record.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
