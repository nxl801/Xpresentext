import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Textream/Murmury"))
from PySide6.QtWidgets import QApplication
from panel import PresenterPanel
from PySide6.QtCore import Qt
from PySide6.QtTest import QTest

class PanelTest(unittest.TestCase):
    app = QApplication.instance() or QApplication([])

    def test_new_context_drops_stale_answer_and_citations(self):
        events = []
        panel = PresenterPanel(events.append)
        panel.receive(dict(type="state", context="a", title="Pilot", question="How many?", short="North 37%.",
                           sources=[dict(id="chart1", label="第 8 页 · 图表")], status="完成"))
        self.assertIn("North 37%", panel.cards[1][2].text())
        panel.open_source("cite:0")
        self.assertEqual(events[-1], dict(action="preview", context="a", id="chart1"))
        panel.receive(dict(type="state", context="b", title="Revision", question="", status=""))
        panel.open_source("cite:0")
        self.assertEqual(len(events), 1)
        self.assertFalse(panel.cards)
        panel.show()
        panel.input.setText("Why North?")
        QTest.keyClick(panel.input, Qt.Key_Return)
        self.assertEqual(events[-1], dict(action="ask", context="b", text="Why North?", id="", follow=False))
        panel.receive(dict(type="state", context="b", question="Why not?", transcriptID="turn",
                           short="A short reply.", details=["Full reasoning."], canFollow=True))
        panel.correct.click()
        self.assertEqual(panel.input.text(), "Why not?")
        panel.input.setText("Why North?")
        QTest.keyClick(panel.input, Qt.Key_Return)
        self.assertEqual(events[-1]["id"], "turn")
        self.assertEqual(events[-1]["action"], "correct")
        panel.more.click()
        self.assertIn("Full reasoning.", panel.cards[1][2].text())
        panel.close()

if __name__ == "__main__":
    unittest.main()
