import unittest

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'Textream' / 'Murmury'))
from english_coverage.schedule import check_start_times


class ScheduleEvidenceTests(unittest.TestCase):
    def test_two_events_are_independent(self):
        points = ['The rehearsal starts at half past nine.', 'The briefing starts at nine thirty.',
                  'The rehearsal begins at ten.']
        for speech in ['The briefing begins at 9:30, and the rehearsal starts at 10.',
                       'The briefing starts at nine thirty. The rehearsal begins at ten.']:
            self.assertEqual(check_start_times(speech, points, [1, 1, 1]), [0, 1, 1])

    def test_registration_is_a_different_subject(self):
        speech = 'Workshop registration starts at 9.30 and the workshop begins at 10.'
        self.assertEqual(check_start_times(speech, ['The workshop starts at nine thirty.'], [1]), [0])

    def test_unsupported_or_ambiguous_times_preserve_the_score(self):
        points = ['The rehearsal starts at 9:40.']
        for speech in ['The rehearsal starts at nine or ten. The briefing begins at ten.',
                       'The rehearsal starts at nine forty and the briefing begins at ten.']:
            self.assertEqual(check_start_times(speech, points, [.75]), [.75])
