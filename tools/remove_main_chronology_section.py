#!/usr/bin/env python3
"""Remove the reader-facing chronology section from the main manuscript DOCX."""

from pathlib import Path
from shutil import copy2

from docx import Document


ROOT = Path(__file__).resolve().parents[1]
DOCX = ROOT / "manuscript" / "manuscript_JTM_multifoundation_atlas.docx"
BACKUP = DOCX.with_name(
    "manuscript_JTM_multifoundation_atlas.before_chronology_section_removal.docx"
)
START_HEADING = "Analysis chronology and terminology"
END_HEADING = "Software, transparency and validation status"


def delete_paragraph(paragraph):
    element = paragraph._element
    element.getparent().remove(element)
    paragraph._p = paragraph._element = None


copy2(DOCX, BACKUP)
document = Document(DOCX)
paragraphs = list(document.paragraphs)

start = next(
    (i for i, paragraph in enumerate(paragraphs) if paragraph.text.strip() == START_HEADING),
    None,
)
if start is None:
    raise RuntimeError(f"Heading not found: {START_HEADING}")

end = next(
    (
        i
        for i, paragraph in enumerate(paragraphs[start + 1 :], start + 1)
        if paragraph.text.strip() == END_HEADING
    ),
    None,
)
if end is None:
    raise RuntimeError(f"Following heading not found: {END_HEADING}")

removed = [paragraph.text for paragraph in paragraphs[start:end]]
for paragraph in paragraphs[start:end]:
    delete_paragraph(paragraph)

document.save(DOCX)
print(f"Removed {len(removed)} paragraphs from {DOCX}")
for text in removed:
    print(f"- {text}")
