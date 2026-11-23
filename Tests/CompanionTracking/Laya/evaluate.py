"""Print recorded results, or re-run the cases with a locally installed Laya SDK."""

import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


HERE = Path(__file__).resolve().parent


def read_rows(filename):
    with (HERE / filename).open(encoding="utf-8", newline="") as source:
        return list(csv.DictReader(source, delimiter="\t"))


def premise(speech, claim):
    return f"Premise: {speech}\nHypothesis: {claim}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replay", help="Local checkpoint directory (requires the upstream laya SDK)")
    parser.add_argument("--language", choices=["en", "zh"], default="en")
    parser.add_argument("--device", default="cpu")
    args = parser.parse_args()
    en = json.loads((HERE / "english-questions.json").read_text(encoding="utf-8"))
    prompts = json.loads((HERE / "inference-questions.json").read_text(encoding="utf-8"))
    rows = read_rows("english.tsv")
    paired = {row["id"]: row for row in read_rows("entailment.tsv")}
    if set(paired) != {row["id"] for row in rows} or len(paired) != len(rows):
        raise ValueError("English case IDs must match across observations")
    claims = en["claims"]
    extra = read_rows("new-claims.tsv")
    zh = read_rows("chinese.tsv")

    if args.replay:
        import laya

        model = laya.load(str(Path(args.replay).resolve(strict=True)), device=args.device)

        def emit(case_id, mode, state, questions):
            result = model.predict(state, questions)
            print(json.dumps({"id": case_id, "mode": mode, "answers": result["answers"]},
                             ensure_ascii=False), flush=True)

        if args.language == "en":
            rubric = {key: {"type": "score",
                            "instructions": en["scoreInstructionPrefix"] + claim,
                            "criteria": en["scoreCriteria"]} for key, claim in claims.items()}
            for row in rows:
                if row["set"] == "base":
                    emit(row["id"], "score", row["speech"], rubric)
                emit(row["id"], "choice", row["speech"], en["choice"])
                for key, claim in claims.items():
                    emit(row["id"], key, premise(row["speech"], claim), prompts["englishEntailment"])
            for row in extra:
                emit(row["id"], "entailment", premise(row["speech"], row["claim"]),
                     prompts["englishEntailment"])
        else:
            # Match the published Space's state wrapper and additional preset questions.
            for row in zh:
                key = row["claim"]
                question, *choices = prompts["chineseChoice"][key]
                nli = prompts["englishEntailment"]["relation"]
                for mode, text, q, opts in [
                    ("choice", row["speech"], question, choices),
                    ("entailment", premise(row["speech"], prompts["chineseClaims"][key]),
                     f"Case {row['id']}. {nli['instructions']}", list(nli["criteria"])),
                ]:
                    state = dict.fromkeys(("message", "body", "prompt", "post"), text)
                    questions = laya.triage_questions()
                    questions[q] = {"type": "choice",
                                    "instructions": f"Looking only at `message`: {q.rstrip('?')}?",
                                    "criteria": {option: option for option in opts}}
                    emit(row["id"], mode, state, questions)
        return

    groups = defaultdict(list)
    times = defaultdict(list)
    for row in rows:
        part = row["set"]
        expected = set() if row["expected"] == "-" else set(row["expected"].split())
        if not expected <= claims.keys():
            raise ValueError(row["id"])
        for key in claims:
            spoken = key in expected
            if row["score_ms"]:
                groups["en score/base"].append((spoken, float(row[f"score_{key}"]), 2.0))
            probability = float(row[f"p_{key}_pct"]) / 100
            groups["en choice/" + part].append((spoken, probability, 0.8))
            nli = paired[row["id"]]
            groups["en NLI/" + part].append((spoken, float(nli[f"p_{key}_pct"]) / 100, 0.8))
            times["en NLI (1 claim)"].append(int(nli[f"ms_{key}"]))
        times["en choice (3 claims)"].append(int(row["choice_ms"]))
        if row["score_ms"]:
            times["en score (3 claims)"].append(int(row["score_ms"]))
    for row in extra:
        groups["en NLI/new claims"].append((bool(int(row["expected"])), float(row["p_entail_pct"]) / 100, 0.8))
        times["en NLI (1 claim)"].append(int(row["ms"]))
    for row in zh:
        for field in ["p_specific", "p_entail"]:
            groups["zh " + field].append((bool(int(row["expected"])), float(row[field]), 0.8))

    print("group\tTP\tFP\tFN\tTN\tpositive/negative score ranges")
    for name, obs in groups.items():
        counts = defaultdict(int)
        for truth, value, cutoff in obs:
            counts[truth, value >= cutoff] += 1
        pos = [v for truth, v, _ in obs if truth]
        neg = [v for truth, v, _ in obs if not truth]
        print(name, counts[True, True], counts[False, True], counts[True, False],
              counts[False, False], f"{min(pos):.3f}–{max(pos):.3f} / {min(neg):.3f}–{max(neg):.3f}",
              sep="\t")
    print("model time (ms)\tn\tmedian\tp95 (nearest rank)")
    for name, samples in times.items():
        print(name, len(samples), statistics.median(samples),
              sorted(samples)[math.ceil(0.95 * len(samples)) - 1], sep="\t")
    all_pairs = [pair for name, pairs in groups.items() if name.startswith("en NLI/") for pair in pairs]
    print("English entailment cutoff\tcorrectly grey\tincorrectly grey")
    for cutoff in (0.50, 0.60, 0.70, 0.80):
        marked = [truth for truth, probability, _ in all_pairs if probability >= cutoff]
        print(cutoff, sum(marked), len(marked) - sum(marked), sep="\t")


if __name__ == "__main__":
    main()
