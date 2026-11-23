"""Compare local raw probabilities to the Ultra L author's rounded reference outputs."""
import argparse

from evaluate import HERE, aligned, dataset, read_json
from english_coverage.model import FineCat


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('model', help='Pinned FineCat Ultra L model directory')
    args = parser.parse_args()
    model = FineCat(args.model)
    comparisons = []
    for page, reference in aligned(dataset('integration-audio'), read_json(HERE / 'reference-scores.json')):
        for (text, _), expected in aligned(page['cases'], reference):
            actual = model.score(text, page['points'])
            comparisons.extend(abs(a - b) for a, b in aligned(actual, expected))
    print(f'{len(comparisons)} probabilities, maximum absolute difference {max(comparisons):.6f}')
    # Reference UI rounds each probability to three decimal places.
    if max(comparisons) > 0.0006:
        raise SystemExit('Model probabilities differ from the reference')


if __name__ == '__main__':
    main()
