#!/usr/bin/env python3
"""Standardize residual multiresponse wording in a reader-facing DOCX."""

from pathlib import Path
from shutil import copy2
from zipfile import ZIP_DEFLATED, ZipFile

from lxml import etree


ROOT = Path(__file__).resolve().parents[1]
DOCX = ROOT / "manuscript" / "response_to_reviewer_JTM.docx"
BACKUP = DOCX.with_name("response_to_reviewer_JTM.before_multioutcome_wording_cleanup.docx")
REPLACEMENTS = {
    "future multiresponse immune resource": "future multi-outcome immune resource",
    "matched multiresponse ridge baseline": "matched multi-outcome ridge baseline",
    "multiresponse": "multi-outcome",
}
NS = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}


copy2(DOCX, BACKUP)
temp = DOCX.with_suffix(".tmp.docx")
changed = 0

with ZipFile(DOCX, "r") as source, ZipFile(temp, "w", ZIP_DEFLATED) as target:
    for item in source.infolist():
        data = source.read(item.filename)
        if item.filename.startswith("word/") and item.filename.endswith(".xml"):
            root = etree.fromstring(data)
            for node in root.xpath("//w:t", namespaces=NS):
                original = node.text or ""
                revised = original
                for old, new in REPLACEMENTS.items():
                    revised = revised.replace(old, new)
                if revised != original:
                    node.text = revised
                    changed += 1
            data = etree.tostring(
                root, xml_declaration=True, encoding="UTF-8", standalone=True
            )
        target.writestr(item, data)

temp.replace(DOCX)
print(f"{DOCX}: {changed} text nodes changed")
