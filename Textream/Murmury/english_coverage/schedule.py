"""Veto a start time expressly attributed to a different named event."""
import re

HOURS = 'one two three four five six seven eight nine ten eleven twelve'.split()
NUMBERS = {word: i for i, word in enumerate(HOURS, 1)}
HOUR = r'(?:' + '|'.join(HOURS) + r'|1[0-2]|0?[1-9])'
START = re.compile(
    rf"\b([a-z]+)\s+(?:starts?|begins?)\s+at\s+"
    rf"(?:(half past|quarter past)\s+)?({HOUR})(?:[:.]([0-5]\d)|\s+(thirty|fifteen))?"
    r"\b(?![.:]\d)(?!\s+(?:or|ish|twenty|forty|fifty|oh|to|past)\b)", re.I)
PRONOUNS = {'it', 'that', 'this', 'we', 'they', 'he', 'she', 'which', 'actually', 'also'}


def starts(text):
    for event, before, hour, digits, after in START.findall(text.lower()):
        if event in PRONOUNS:
            continue
        hours = int(hour) if hour.isdigit() else NUMBERS[hour]
        minutes = int(digits) if digits else {
            'half past': 30, 'thirty': 30, 'quarter past': 15, 'fifteen': 15
        }.get(before or after, 0)
        yield event, (hours % 12, minutes)


def check_start_times(transcript, points, probabilities):
    events = {}
    for name, clock in starts(transcript):
        events.setdefault(name, set()).add(clock)
    if len(events) < 2:
        return probabilities
    result = list(probabilities)
    for i, point in enumerate(points):
        for name, clock in starts(point):
            observed = events.get(name, set())
            if len(observed) == 1 and clock not in observed:
                result[i] = 0.
    return result
