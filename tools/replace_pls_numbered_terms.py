#!/usr/bin/env python3
"""Replace numbered PLS terminology in reader-facing Word documents."""

from pathlib import Path
from shutil import copy2
from zipfile import ZIP_DEFLATED, ZipFile

from lxml import etree


ROOT = Path(__file__).resolve().parents[1]
FILES = [
    ROOT / "manuscript" / "manuscript_JTM_multifoundation_atlas.docx",
    ROOT / "manuscript" / "supplementary_material_JTM.docx",
    ROOT / "manuscript" / "response_to_reviewer_JTM.docx",
]

REPLACEMENTS = [
    (
        "PLS, partial least squares; PLS1, single-response PLS; PLS2, multi-response PLS;",
        "PLS, partial least squares;",
    ),
    ("PLS1-versus-PLS2", "single-outcome versus multi-outcome PLS"),
    ("PLS1–PLS2", "single-outcome versus multi-outcome PLS"),
    ("PLS1-PLS2", "single-outcome versus multi-outcome PLS"),
    ("PLS1/PLS–LDA", "PLS regression/PLS-LDA"),
    ("PLS1/PLS-LDA", "PLS regression/PLS-LDA"),
    ("PLS1 or PLS–LDA", "PLS regression or PLS-LDA"),
    ("PLS1 or PLS-LDA", "PLS regression or PLS-LDA"),
    ("PLS1 and PLS2", "single-outcome and multi-outcome PLS"),
    (
        "Response-by-response PLS1 and joint PLS2",
        "Separate single-outcome PLS models and joint multi-outcome PLS",
    ),
    ("response-by-response PLS1", "separate single-outcome PLS models"),
    ("joint PLS2", "joint multi-outcome PLS"),
    ("PLS1 regression", "PLS regression"),
    ("Continuous outcomes used PLS1", "Continuous outcomes used PLS regression"),
    ("PLS1 continuous", "PLS regression for continuous outcomes"),
    ("PLS1 and PLS-LDA", "PLS regression and PLS-LDA"),
    ("PLS1 and PLS–LDA", "PLS regression and PLS-LDA"),
    ("PLS2 remains secondary", "Multi-outcome PLS remains secondary"),
    ("PLS2 was not substituted", "Multi-outcome PLS was not substituted"),
    ("PLS2", "multi-outcome PLS"),
    ("PLS1", "single-outcome PLS"),
    ("single-outcome PLS regression", "PLS regression"),
    ("PLS–LDA", "PLS-LDA"),
]

NS = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}


def replace_text(text):
    for old, new in REPLACEMENTS:
        text = text.replace(old, new)
    return text


def process_docx(path):
    backup = path.with_name(path.stem + ".before_reader_friendly_pls_terms.docx")
    copy2(path, backup)
    temp = path.with_suffix(".tmp.docx")
    changed = 0
    with ZipFile(path, "r") as source, ZipFile(temp, "w", ZIP_DEFLATED) as target:
        for item in source.infolist():
            data = source.read(item.filename)
            if item.filename.startswith("word/") and item.filename.endswith(".xml"):
                root = etree.fromstring(data)
                for node in root.xpath("//w:t", namespaces=NS):
                    original = node.text or ""
                    revised = replace_text(original)
                    if revised != original:
                        node.text = revised
                        changed += 1
                data = etree.tostring(
                    root, xml_declaration=True, encoding="UTF-8", standalone=True
                )
            target.writestr(item, data)
    temp.replace(path)
    print(f"{path}: {changed} text nodes changed")


for file_path in FILES:
    process_docx(file_path)
