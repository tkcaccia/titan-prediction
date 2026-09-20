#!/usr/bin/env python3
"""Keep the registration declaration concise after removing chronology prose."""

from pathlib import Path

from docx import Document


ROOT = Path(__file__).resolve().parents[1]
DOCX = ROOT / "manuscript" / "manuscript_JTM_multifoundation_atlas.docx"
OLD = (
    "This retrospective computational benchmark was not registered. The companion "
    "repository contains the documented analysis rules and chronology; the initial "
    "snapshot also contains completed results and therefore does not establish "
    "prospective locking of the main study [37]."
)
NEW = "This retrospective computational benchmark was not prospectively registered."


document = Document(DOCX)
matches = [paragraph for paragraph in document.paragraphs if paragraph.text == OLD]
if len(matches) != 1:
    raise RuntimeError(f"Expected one registration paragraph, found {len(matches)}")

paragraph = matches[0]
if paragraph.runs:
    paragraph.runs[0].text = NEW
    for run in paragraph.runs[1:]:
        run.text = ""
else:
    paragraph.text = NEW

document.save(DOCX)
print(f"Updated registration statement in {DOCX}")
