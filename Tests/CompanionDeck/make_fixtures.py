#!/usr/bin/env python3
"""Generate local PowerPoint fixtures. Requires python-pptx and Pillow."""
import io
from pathlib import Path
import sys
from zipfile import ZIP_DEFLATED, ZipFile

from lxml import etree
from PIL import Image, ImageDraw, ImageFont
from pptx import Presentation
from pptx.chart.data import CategoryChartData
from pptx.dml.color import RGBColor
from pptx.enum.chart import XL_CHART_TYPE
from pptx.enum.shapes import PP_PLACEHOLDER
from pptx.util import Inches

P = "http://schemas.openxmlformats.org/presentationml/2006/main"
P14 = "http://schemas.microsoft.com/office/powerpoint/2010/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG = "http://schemas.openxmlformats.org/package/2006/relationships"
C = "http://schemas.openxmlformats.org/drawingml/2006/chart"


def add_slide(deck, title, notes=None):
    slide = deck.slides.add_slide(deck.slide_layouts[5])
    slide.shapes.title.text = title
    slide.shapes.title.text_frame.paragraphs[0].font.name = "Arial"
    if notes is not None:
        slide.notes_slide.notes_text_frame.text = notes
    return slide


def chart(slide):
    data = CategoryChartData(number_format="0%")
    data.categories = ["Pilot"]
    data.add_series("North", [0.37])
    data.add_series("South", [0.31])
    collection = slide.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED, Inches(1), Inches(2),
                                        Inches(7.5), Inches(4), data).chart
    collection.has_title = True
    collection.chart_title.text_frame.text = "Pilot adoption (%)"
    collection.has_legend = True
    collection.plots[0].has_data_labels = True
    collection.plots[0].data_labels.show_value = True
    collection.plots[0].data_labels.number_format = "0%"


def table_and_screenshot(slide):
    table = slide.shapes.add_table(2, 2, Inches(0.5), Inches(2), Inches(4), Inches(1.5)).table
    for row, values in enumerate((("Series", "Verified units"), ("Delta", "42"))):
        for col, text in enumerate(values):
            table.cell(row, col).text = text
    bitmap = Image.new("RGB", (1000, 500), "white")
    pen = ImageDraw.Draw(bitmap)
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 75)
    pen.text((45, 55), "SCREENSHOT DATA", font=font, fill="black")
    pen.text((45, 180), "South: 31%", font=font, fill="black")
    image = io.BytesIO()
    bitmap.save(image, format="PNG")
    image.seek(0)
    slide.shapes.add_picture(image, Inches(5), Inches(2), width=Inches(4.5))


def parts(path):
    with ZipFile(path) as package:
        return {name: package.read(name) for name in package.namelist()}


def edit_package(src, dest, edit):
    package = parts(src)
    edit(package)
    with ZipFile(dest, "w", ZIP_DEFLATED) as archive:
        for name, value in package.items():
            archive.writestr(name, value)


def element(namespace, name):
    return "{" + namespace + "}" + name


def manifest(package):
    path = "ppt/presentation.xml"
    presentation = etree.fromstring(package[path])
    return path, presentation, presentation.find(element(P, "sldIdLst"))


def reorder(package, order):
    path, presentation, slides = manifest(package)
    original = list(slides)
    for item in original:
        slides.remove(item)
    for index in order:
        slides.append(original[index - 1])
    package[path] = etree.tostring(presentation)


def section(package):
    path, presentation, slides = manifest(package)
    extensions = etree.SubElement(presentation, element(P, "extLst"))
    extension = etree.SubElement(extensions, element(P, "ext"), uri="{521415D9-36F7-43E2-AB2F-B90AF26B5E84}")
    sections = etree.SubElement(extension, element(P14, "sectionLst"))
    node = etree.SubElement(sections, element(P14, "section"), name="Backup slides", id="{C11E2C56-CB22-4198-B0E6-3B8150C3B1A4}")
    ids = etree.SubElement(node, element(P14, "sldIdLst"))
    etree.SubElement(ids, element(P14, "sldId"), id=slides[1].get("id"))
    package[path] = etree.tostring(presentation)


def changed_chart(package):
    path = "ppt/charts/chart1.xml"
    node = etree.fromstring(package[path])
    for value in node.findall(".//" + element(C, "v")):
        if value.text == "0.37":
            value.text = "0.29"
    package[path] = etree.tostring(node)
    for path in package.keys():
        if not path.startswith("ppt/embeddings/") or not path.endswith(".xlsx"):
            continue
        with ZipFile(io.BytesIO(package[path])) as workbook:
            workbook_parts = {name: workbook.read(name) for name in workbook.namelist()}
        sheet = "xl/worksheets/sheet1.xml"
        worksheet = etree.fromstring(workbook_parts[sheet])
        for value in worksheet.xpath(".//*[local-name()='v']"):
            if value.text == "0.37":
                value.text = "0.29"
        workbook_parts[sheet] = etree.tostring(worksheet)
        updated = io.BytesIO()
        with ZipFile(updated, "w", ZIP_DEFLATED) as workbook:
            for name, value in workbook_parts.items():
                workbook.writestr(name, value)
        package[path] = updated.getvalue()
    reorder(package, [1, 2, 3, 4, 5, 6, 7, 9, 11, 8, 12])


def similar_chart(package):
    path, presentation, slides = manifest(package)
    relations_path = "ppt/_rels/presentation.xml.rels"
    relationships = etree.fromstring(package[relations_path])
    etree.SubElement(relationships, element(PKG, "Relationship"), Id="rId300",
                     Type=R + "/slide", Target="slides/slide13.xml")
    etree.SubElement(slides, element(P, "sldId"), id="500", attrib={element(R, "id"): "rId300"})
    package[relations_path] = etree.tostring(relationships)
    package[path] = etree.tostring(presentation)
    package["ppt/slides/slide13.xml"] = package["ppt/slides/slide8.xml"]
    package["ppt/slides/_rels/slide13.xml.rels"] = package["ppt/slides/_rels/slide8.xml.rels"]
    # The duplicated slide needs its own content-type declaration.
    content_types = "[Content_Types].xml"
    root = etree.fromstring(package[content_types])
    etree.SubElement(root, element("http://schemas.openxmlformats.org/package/2006/content-types", "Override"),
                     PartName="/ppt/slides/slide13.xml",
                     ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml")
    package[content_types] = etree.tostring(root)


def main(folder):
    folder.mkdir(parents=True, exist_ok=True)
    notes = Presentation()
    cover = add_slide(notes, "Title 1", "Open with the goal.")
    cover.background.fill.solid()
    cover.background.fill.fore_color.rgb = RGBColor(26, 91, 64)
    hidden = add_slide(notes, "Title 2 - hidden")
    hidden._element.set("show", "0")
    fourth = add_slide(notes, "Title 4", "0")
    bullets = fourth.shapes.add_textbox(Inches(1), Inches(2), Inches(7), Inches(3))
    bullets.text = "Orchard maintenance budget\nGarden equipment inventory"
    for paragraph in bullets.text_frame.paragraphs:
        style = paragraph._p.get_or_add_pPr()
        etree.SubElement(style, "{http://schemas.openxmlformats.org/drawingml/2006/main}buChar", char="•")
    for shape in fourth.notes_slide.placeholders:
        if shape.placeholder_format.type == PP_PLACEHOLDER.SLIDE_NUMBER:
            shape.text = "4"
    third = add_slide(notes, "Title 3", "关键点一\n\n关键点二\v[指向图表]\nKeep going.")
    link = third.shapes.add_textbox(Inches(1), Inches(3), Inches(6), Inches(1))
    run = link.text_frame.paragraphs[0].add_run()
    run.text = "Local rendering fixture link"
    run.hyperlink.address = "https://example.invalid/local-fixture"
    raw = folder / "original-parts.pptx"
    notes.save(raw)
    edit_package(raw, folder / "notes.pptx", lambda package: reorder(package, [1, 2, 4, 3]))
    raw.unlink()

    no_notes = Presentation()
    add_slide(no_notes, "Initial")
    add_slide(no_notes, "Planned outcomes")
    add_slide(no_notes, "Reference data")
    no_notes.save(folder / "no-notes.pptx")
    edit_package(folder / "no-notes.pptx", folder / "section.pptx", section)

    repeated_title = Presentation()
    first = add_slide(repeated_title, "Calibration objectives", "Original gauge note.")
    first.shapes.add_textbox(Inches(1), Inches(2), Inches(8), Inches(1)).text = "The amber gauge shows local pressure."
    second = add_slide(repeated_title, "Pressure test procedure", "Original valve note.")
    second.shapes.add_textbox(Inches(1), Inches(2), Inches(8), Inches(1)).text = "Calibration objectives\nThe inlet stays isolated."
    repeated_title.save(folder / "repeated-title.pptx")

    main_deck = Presentation()
    for index in range(1, 13):
        title = {8: "Pilot chart", 9: "附录", 10: "Removed in changed revision"}.get(index, f"Slide {index}")
        slide = add_slide(main_deck, title, None if index == 8 else f"Speaker notes for {index}")
        if index == 8:
            chart(slide)
        if index == 10:
            table_and_screenshot(slide)
    main_deck.save(folder / "full.pptx")
    edit_package(folder / "full.pptx", folder / "original.pptx", lambda package: reorder(package, range(1, 11)))
    edit_package(folder / "full.pptx", folder / "reordered.pptx",
                 lambda package: reorder(package, [1, 2, 3, 4, 5, 6, 7, 9, 11, 8, 10, 12]))
    edit_package(folder / "full.pptx", folder / "changed.pptx", changed_chart)
    edit_package(folder / "reordered.pptx", folder / "ambiguous.pptx", similar_chart)
    (folder / "full.pptx").unlink()


if __name__ == "__main__":
    main(Path(sys.argv[1]))
