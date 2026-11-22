#!/usr/bin/env python3
"""Select saved Apple partials and independent controls for a local sentence-vector trial."""

import json
import sys
from pathlib import Path


def main():
    source, output = map(Path, sys.argv[1:])
    plan = json.loads((source / "synthetic-plan.json").read_text())
    corpus = {clip["id"]: clip for clip in json.loads((source / "shared-transcripts.json").read_text())["clips"]}
    groups = {
        "same-page": {f"8.{i+1}": text for i, text in enumerate(plan["pages"][1])},
        "cross-page": {"8.4": plan["pages"][1][3], **{f"10.{i+1}": text for i, text in enumerate(plan["pages"][2])}},
        "isolated-opener": {
            "2.2": plan["pages"][0][1], "2.3": plan["pages"][0][2],
            "8.1": plan["pages"][1][0], "8.2": plan["pages"][1][1],
        },
        "independent": {
            "example.1": "The new lock prevents the seal from opening under pressure.",
            "example.2": "The safety valve releases pressure when the limit is exceeded.",
            "example.3": "Following the test, record the highest pressure in the inspection register.",
        },
    }
    rows = []

    def apple(label, group, clip_id, start, end, marker, checkpoint, expected=None, phase="following"):
        file = source / "offline-e2/apple" / f"{clip_id}.jsonl"
        if not file.exists():
            file = source / "apple/file" / f"{clip_id}.jsonl"
        reference = corpus[clip_id]["events"][checkpoint]["referenceMs"]
        samples = []
        for line in file.read_text().splitlines():
            event = json.loads(line)
            if not start <= event["atMs"] <= end:
                continue
            text = event["transcript"]
            offset = text.lower().rfind(marker)
            if offset >= 0:
                samples.append({"timeMs": event["atMs"], "oracle": text[offset:], "tail": " ".join(text.split()[-10:])})
        if not samples:
            raise ValueError(f"No saved Apple samples for {clip_id}/{label}")
        rows.append({
            "id": label, "phase": phase, "group": group, "target": expected,
            "source": str(file.relative_to(source)), "annotationMs": reference, "samples": samples,
        })

    apple("real-strong-rewording", "same-page", "semantic-paraphrase", 3430, 6760, "first", 1, "8.2")
    apple("real-cross-page", "cross-page", "read-through-3-pages", 25000, 27230, "we can only", 7, "10.1")
    apple("real-light-rewording", "isolated-opener", "skip-and-light-paraphrase", 4100, 7000, "our focus", 1, "2.3")
    apple("real-ad-lib", "isolated-opener", "ad-lib-with-overlap", 6300, 12100, "let me give", 1)
    apple("real-ad-lib-quotes-opener", "isolated-opener", "ad-lib-with-overlap", 12500, 14800, "the china", 2)
    apple("real-question-quotes-next-line", "same-page", "slow-question-repeats-next-line", 4350, 6400,
          "your next point", 0, phase="listeningQuestion")
    apple("real-answer-says-next-line", "same-page", "answer-then-natural-resume", 1300, 3800,
          "another is to", 0, phase="awaitingResume")

    def control(label, group, text, target=None):
        rows.append({"id": label, "phase": "following", "group": group, "target": target,
                     "source": "independent text control", "samples": [{"oracle": text, "tail": " ".join(text.split()[-10:])}]})

    control("rewrite-ai-foundations", "same-page", "We should give artificial intelligence a much stronger foundation.", "8.2")
    control("tangent-existing-vendor-foundation", "same-page", "Here is a different example: the vendor already has an excellent artificial intelligence foundation.")
    control("tangent-contradicts-ai-foundations", "same-page", "We already have strong AI foundations, so we have no need to strengthen them.")
    control("tangent-accounting", "same-page", "For example, we could describe a workflow and ask people to review the paperwork.")
    control("rewrite-short-outlook", "cross-page", "We can see only a little way into the future.", "10.1")
    control("tangent-hypothetical-outlook", "cross-page", "Suppose, instead, that we could see only a short distance ahead.")
    control("tangent-quotes-short-outlook", "cross-page", "Someone asked why we can only see a short distance ahead.")
    control("tangent-literal-crossing", "cross-page", "We can only see a short distance ahead.")
    control("independent-rewrite-safety", "independent", "If pressure gets too high, the valve vents it.", "example.2")
    control("independent-rewrite-logging", "independent", "After testing, write the maximum pressure in the log.", "example.3")
    control("independent-rewrite-lock", "independent", "With pressure in the chamber, the lock keeps the seal shut.", "example.1")
    control("independent-false-inverted-safety", "independent", "This example has no safety valve and holds pressure above the limit.")
    control("independent-false-record-middle", "independent", "A similar test records the lowest pressure in a spreadsheet before the trial begins.")
    control("independent-false-quotes-valve", "independent", "The safety valve releases pressure when the limit is exceeded, in the observer's hypothetical example.")

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"groups": groups, "cases": rows}, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
