"""Compare recorded English coverage decisions or run the same tests on a local model."""
import argparse
import csv
import json
from collections import Counter
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'Textream' / 'Murmury'))
from english_coverage.decision import THRESHOLD, check_coverage

HERE = Path(__file__).resolve().parent
SETS = {
    'held-out': 'held-out', 'status-holdout': 'status-holdout', 'status-audio': 'status-holdout',
    'final-holdout': 'final-holdout', 'final-audio': 'final-holdout',
    'replication': 'replication', 'replication-audio': 'replication',
    'acceptance': 'acceptance', 'acceptance-audio': 'acceptance',
    'integration-audio': 'integration-trial', 'integration-turbo-audio': 'integration-trial',
}


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8'))


def read_lines(path):
    return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]


def dataset(name):
    pages = read_json(HERE / (SETS[name] + '.json'))
    if name.endswith('-audio'):
        transcripts = {(i, j): t for i, j, t in read_lines(HERE / (name + '.jsonl'))}
        for i, page in enumerate(pages):
            for j, case in enumerate(page['cases']):
                case[0] = transcripts.pop((i, j))
        if transcripts:
            raise ValueError(f'Unexpected transcript in {name}')
    return pages


def count_results(probabilities, positives):
    positives = set(positives)
    if not positives <= set(range(len(probabilities))):
        raise ValueError("Reference label outside candidate list")
    counts = Counter()
    for i, value in enumerate(probabilities):
        predicted = value >= THRESHOLD
        counts['tp' if predicted and i in positives else
               'fp' if predicted else 'fn' if i in positives else 'tn'] += 1
    return counts


def aligned(left, right):
    if len(left) != len(right):
        raise ValueError('Fixture and observation lengths differ')
    return zip(left, right)


def development(observations):
    with (HERE.parent / 'Laya' / 'english.tsv').open() as f:
        rows = list(csv.DictReader(f, delimiter='\t'))
    with (HERE.parent / 'Laya' / 'new-claims.tsv').open() as f:
        numeric = list(csv.DictReader(f, delimiter='\t'))
    labels = ['meetings', 'tracing', 'approval']
    result = Counter()
    for row, probabilities in aligned(rows, observations['development']):
        expected = row['expected'].split()
        result.update(count_results(probabilities, [i for i, key in enumerate(labels) if key in expected]))
    for row, score in aligned(numeric, observations['development_numbers']):
        result.update(count_results([score], [0] if row['expected'] == '1' else []))
    return result


def local_scorer(directory):
    # Use an explicitly supplied model directory. The official UltraBERT model
    # contains custom code. A local path and offline mode prevent downloads.
    import os
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    from sentence_transformers import CrossEncoder
    model = CrossEncoder(str(directory.resolve(strict=True)), trust_remote_code=True,
                         local_files_only=True, device='cpu')
    labels = model.model.config.id2label
    entailment = next(int(i) for i, label in labels.items() if label.lower() == 'entailment')

    def predict(context, points):
        scores = model.predict([(context, p) for p in points], apply_softmax=True,
                               show_progress_bar=False)
        return [float(row[entailment]) for row in scores]
    return predict


def stats(counts):
    positives = counts['tp'] + counts['fn']
    negatives = counts['fp'] + counts['tn']
    return f"{counts['tp']}/{positives} spoken ({100*counts['tp']/positives:.1f}%), {counts['fp']}/{negatives} false grey"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', type=Path, help='Local FineCat Ultra L directory for new predictions')
    parser.add_argument('--set', choices=SETS, action='append', dest='sets')
    parser.add_argument('--errors', action='store_true', help='Show missed points and false grays')
    parser.add_argument('--input', type=Path, help='With --model, read JSON with slide, points, transcript')
    args = parser.parse_args()
    if args.input and not args.model:
        parser.error('--input needs --model')
    predict = local_scorer(args.model) if args.model else None
    if args.input:
        request = read_json(args.input)
        probabilities = check_coverage(request['transcript'], request['points'], predict, request['slide'])
        print(json.dumps([{'point': p, 'support': v, 'covered': v >= THRESHOLD}
                          for p, v in zip(request['points'], probabilities)], indent=2))
        return

    observations = read_json(HERE / 'observations.json')
    print('FineCat, original Laya samples, recorded raw model:', stats(development(observations)))
    extras = {(slide, context): values for slide, context, values in read_lines(HERE / 'additional-scores.jsonl')}
    for name in (args.sets or [key for key in SETS if key in observations]):
        if name not in observations:
            parser.error(f"Use evaluate_app.py --set {name} to run the packaged model on this fixture")
        raw, optimized = Counter(), Counter()
        for page, observed in aligned(dataset(name), observations[name]):
            points = page['points']
            for (speech, labels), original in aligned(page['cases'], observed):
                def recorded(context, candidates):
                    if candidates != points:
                        raise ValueError("Candidate order changed")
                    return original if context == speech else extras[page['slide'], context]
                infer = predict or recorded
                raw.update(count_results(infer(speech, points), labels))
                scores = check_coverage(speech, points, infer, page['slide'])
                optimized.update(count_results(scores, labels))
                if args.errors:
                    for i, value in enumerate(scores):
                        if (value >= THRESHOLD) != (i in labels):
                            print('  ', 'MISS' if i in labels else 'FALSE GRAY', page['slide'],
                                  round(value, 3), speech, '=>', points[i])
        print(f'{name:20} raw {stats(raw)} | optimized {stats(optimized)}')


if __name__ == '__main__':
    main()
