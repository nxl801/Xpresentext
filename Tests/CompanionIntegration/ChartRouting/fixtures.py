import sys
from pathlib import Path

from pptx import Presentation
from pptx.chart.data import CategoryChartData
from pptx.enum.chart import XL_CHART_TYPE
from pptx.util import Inches, Pt


def label(slide, text, x, y, w, h, name):
    shape = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    shape.name = name
    p = shape.text_frame.paragraphs[0]
    p.text = text
    p.font.name = 'Arial'
    p.font.size = Pt(20)


def fixture(path, detached, overlapping=False):
    deck = Presentation()
    deck.slide_width = Inches(13.3333333)
    deck.slide_height = Inches(7.5)
    slide = deck.slides.add_slide(deck.slide_layouts[6])
    label(slide, 'Pilot roll-out', 0.7, 0.2, 10, 0.60, 'Slide heading')
    values = CategoryChartData(number_format='0')
    values.categories = ['Pilot']
    values.add_series('North', [37])
    values.add_series('South', [31])
    chart = slide.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED, Inches(1), Inches(1.65),
                                   Inches(7.1), Inches(4.5), values).chart
    chart.has_legend = not detached
    chart.has_title = not detached
    if detached:
        label(slide, 'Chart title: Pilot adoption', 0.95, 1.02, 7.1, 0.48, 'Chart title')
        label(slide, 'Legend: North / South', 8.48, 2.15, 4.25, 0.8, 'Chart Legend')
        label(slide, 'Units: %', 8.48, 3.25, 4.25, 0.6, 'Axis units')
    else:
        chart.chart_title.text_frame.text = 'Pilot adoption (%)'
        label(slide, 'Unrelated units: kg', 8.42, 2.1, 4.27, 0.8, 'Another topic')
    plot = chart.plots[0]
    plot.has_data_labels = True
    plot.data_labels.font.size = Pt(17)
    plot.data_labels.show_value = True
    # A literal percent suffix remains visible in LibreOffice, but the importer's
    # intentionally limited Excel formatting reader leaves this case for local/Vision reading.
    plot.data_labels.number_format = '0' if detached else '0"%"'
    if overlapping:
        other = slide.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED, Inches(3.3), Inches(2.5),
                                       Inches(5.2), Inches(3.8), values).chart
        other.has_legend = False
        other.plots[0].has_data_labels = True
        other.plots[0].data_labels.show_value = True
        other.plots[0].data_labels.number_format = '0'
    label(slide, 'Unrelated footer 99%', 8.55, 5.28, 4.3, 0.63, 'Unrelated footer')
    slide.notes_slide.notes_text_frame.text = 'Read the pilot adoption chart.'
    later = deck.slides.add_slide(deck.slide_layouts[6])
    label(later, 'OTHER SLIDE ONLY 77%', 2, 2, 9, 1.0, 'Second slide marker')
    deck.save(path)


if __name__ == '__main__':
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    fixture(out / 'separate-legend.pptx', True)
    fixture(out / 'self-contained-chart.pptx', False)
    fixture(out / 'overlapping-charts.pptx', True, overlapping=True)
