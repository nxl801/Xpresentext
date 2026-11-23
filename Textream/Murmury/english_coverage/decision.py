"""Estimate point coverage from a finalized English utterance and its slide."""
import re

from .schedule import check_start_times

THRESHOLD = 0.50
INTENT = re.compile(r"\b(?:plans? (?:to|an?|the|another)|aims? to|hopes? to|intends? to|target|goal|proposal|request(?:s|ed)?|would like to)\b", re.I)
PROSPECTIVE = re.compile(
    r"\b(?:requested|proposed|suggested|asked for|would like to|would love to|"
    r"we['’]d love to|hopes? to|plans? to|intends? to|aims? to|"
    r"(?:plan|goal|target) is to|could we)\b", re.I)
RETRACTED = re.compile(r"\b(?:reject(?:ed)?|abandon(?:ed)?|drop(?:ped)?|withdraw|withdrew|cancel(?:led|ed)?|scrapped)\b", re.I)
# Whisper often joins complete sentences with a comma. Preserve lists and
# dependent clauses, which can contain a critical exception or a condition.
CLAUSE_BOUNDARY = re.compile(
    r"(?<=[.!?])\s+|,\s+(?=(?:we|they|he|she|you|it|our|these|those|I)\b|"
    r"(?:(?:the|a|an|some|only)\s+)?(?:[a-z'-]+\s+){1,4}"
    r"(?:can|could|is|are|was|were|has|have|had|do|does|will|would|may|"
    r"already|currently|still|only|who)\b)", re.I)


def clauses(text):
    return [s.strip() for s in CLAUSE_BOUNDARY.split(text.strip()) if s.strip()]


def check_coverage(transcript, points, score, slide=''):
    """score(context, points) returns entailment probabilities in point order."""
    # A presenter can deliver a scripted question. A spoken question still
    # cannot establish a declarative slide claim about the same subject.
    def tokens(text):
        return re.findall(r"[a-z0-9]+", text.lower())
    scripted_questions = {i for i, point in enumerate(points) if point.rstrip().endswith('?')}
    spoken = tokens(transcript)
    asked = {i for i in scripted_questions if spoken and spoken == tokens(points[i])}
    if transcript.rstrip().endswith('?') and not re.search(r'[.!]\s+\S', transcript):
        return [float(i in asked) for i in range(len(points))]
    probabilities = semantic_coverage(transcript, points, score, slide)
    for i in scripted_questions:
        probabilities[i] = float(i in asked)
    return check_start_times(transcript, points, probabilities)


def semantic_coverage(transcript, points, score, slide):
    if not transcript.strip() or not points:
        return [0.] * len(points)
    def checked(context):
        values = list(score(context, points))
        if len(values) != len(points) or not all(0 <= v <= 1 for v in values):
            raise ValueError("Expected an entailment probability for each point")
        return values

    full = checked(transcript)
    parts = clauses(transcript)
    factual = [part for part in parts if not PROSPECTIVE.search(part)]
    intention = [bool(INTENT.search(p)) for p in points]
    # Check a claim about a delivered outcome using only asserted evidence.
    if len(factual) < len(parts) and any(v >= THRESHOLD and not planned for v, planned in zip(full, intention)):
        corroborated = checked(' '.join(factual)) if factual else [0.] * len(points)
        # A museum's "our audio guide" still refers to the museum when the
        # adjoining sentence about a proposal has been removed.
        if slide and factual and any(v >= THRESHOLD > e and not planned for v,e,planned in zip(full, corroborated, intention)):
            grounded = checked(f"Topic: {slide}. {' '.join(factual)}")
            corroborated = [max(a, b) for a, b in zip(corroborated, grounded)]
        full = [v if planned else min(v, e) for v, e, planned in zip(full, corroborated, intention)]
    if RETRACTED.search(transcript):
        # With a withdrawn proposal, abstain on plans until more evidence arrives.
        return [0. if planned else v for planned, v in zip(intention, full)]
    # If one point matched, a second can have been buried in the same utterance.
    # Only use complete clauses on their own, with the slide title to resolve
    # "we" and other references. Do not split a correction or a counterexample.
    correction = re.search(r"\b(?:but|however|actually|instead|only|except|yet|never)\b", transcript, re.I)
    if slide and len(parts) == 1 and max(full) < THRESHOLD and not correction and not PROSPECTIVE.search(transcript) and not transcript.rstrip().endswith('?'):
        # A short utterance may rely entirely on the slide to name its subject.
        # A heading that already states the point cannot establish it was spoken.
        title_only = checked(f'Topic: {slide}.')
        contextual = checked(f'Topic: {slide}. {transcript}')
        return [max(v, c) if prior < THRESHOLD else v
                for v, c, prior in zip(full, contextual, title_only)]
    if not slide or len(parts) < 2 or max(full) < THRESHOLD or correction:
        return full
    for part in parts:
        relevant = [i for i,v in enumerate(full) if v < THRESHOLD and (intention[i] or part in factual)]
        if relevant:
            context = f'Topic: {slide}. {part}'
            extra = checked(context)
            for i in relevant:
                full[i] = max(full[i], extra[i])
    return full
