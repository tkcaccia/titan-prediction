#!/usr/bin/env python3
"""Replace the two supplementary PLS comparison images in the Word file."""

from pathlib import Path
from shutil import copy2
from zipfile import ZIP_DEFLATED, ZipFile

from docx import Document
from docx.oxml.ns import qn


ROOT = Path(__file__).resolve().parents[1]
DOCX = ROOT / "manuscript" / "supplementary_material_JTM.docx"
BACKUP = ROOT / "manuscript" / "supplementary_material_JTM.before_reader_friendly_pls_figures.docx"
FIGURES = {
    "Figure S3. Matched target-level": ROOT / "figures" / "Figure6a_pls1_vs_pls2_targets.png",
    "Figure S4. Cancer-level mean": ROOT / "figures" / "Figure6b_pls1_vs_pls2_cancers.png",
}


def media_target_for_caption(document, prefix):
    paragraphs = document.paragraphs
    for index, paragraph in enumerate(paragraphs):
        if paragraph.text.startswith(prefix):
            if index == 0:
                break
            drawing = paragraphs[index - 1]
            blips = drawing._p.xpath(".//a:blip")
            if not blips:
                raise RuntimeError(f"No drawing found before {prefix}")
            relationship_id = blips[0].get(qn("r:embed"))
            return document.part.rels[relationship_id].target_part.partname.lstrip("/")
    raise RuntimeError(f"Caption not found: {prefix}")


document = Document(DOCX)
replacements = {
    media_target_for_caption(document, caption): figure.read_bytes()
    for caption, figure in FIGURES.items()
}

copy2(DOCX, BACKUP)
temporary = DOCX.with_suffix(".tmp.docx")
with ZipFile(DOCX, "r") as source, ZipFile(temporary, "w", ZIP_DEFLATED) as target:
    for item in source.infolist():
        payload = replacements.get(item.filename, source.read(item.filename))
        target.writestr(item, payload)
temporary.replace(DOCX)

for target_name in replacements:
    print(target_name)
