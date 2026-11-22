from pathlib import Path
import sys

from pptx import Presentation
from pptx.util import Inches


def slide(deck, title, notes):
    page = deck.slides.add_slide(deck.slide_layouts[6])
    page.shapes.add_textbox(Inches(1), Inches(1), Inches(8), Inches(1)).text = title
    page.notes_slide.notes_text_frame.text = notes


def fixture(destination, footer):
    deck = Presentation()
    slide(deck, "Fixture title to omit " + footer, "\n".join([
        "The queue starts with no stored records.",
        "[PACKAGING CUE] Discard duplicate deliveries before writing the ledger.",
        "Node coverage reached 37% using the local baseline.",
    ]))
    slide(deck, "Chinese", "这个合成测试的中文内容不应发送。")
    slide(deck, "Supporting material", "The appendix holds supporting reference records only.")
    deck.save(destination)


out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
fixture(out / "original.pptx", "original")
fixture(out / "revision.pptx", "updated")
