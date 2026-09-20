#!/usr/bin/env python3
"""Audit the synchronized Journal of Translational Medicine submission files."""
from __future__ import annotations

import re
from pathlib import Path
from docx import Document

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "manuscript"
CURRENT = {
    "manuscript_JTM_multifoundation_atlas.docx",
    "supplementary_material_JTM.docx",
    "response_to_reviewer_JTM.docx",
    "cover_letter_JTM.docx",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def text(document: Document) -> str:
    chunks = [p.text for p in document.paragraphs]
    for table in document.tables:
        for row in table.rows:
            chunks.extend(cell.text for cell in row.cells)
    return "\n".join(chunks)


for name in CURRENT:
    require((OUT / name).exists(), f"Missing current document: {name}")

main = Document(OUT / "manuscript_JTM_multifoundation_atlas.docx")
supp = Document(OUT / "supplementary_material_JTM.docx")
response = Document(OUT / "response_to_reviewer_JTM.docx")
cover = Document(OUT / "cover_letter_JTM.docx")
main_text = text(main)
supp_text = text(supp)
response_text = text(response)
cover_text = text(cover)
combined = "\n".join((main_text, supp_text, response_text, cover_text))

require("Patient-level comparison of three released pathology representation pipelines" in main_text,
        "Current title is missing")
require("8,241" in main_text and "3,389" in main_text and "30 cancers" in main_text,
        "Current matched-cohort counts are missing")
require("1 to 20" in main_text or "1-to-20" in main_text,
        "Current 1 to 20 component range is missing")
require("TITAN" in main_text and "Giga-SSL" in main_text and "Prov-GigaPath" in main_text,
        "All three representations are not named")
require("PathoFMPred" in main_text and "PathoFMPred" in supp_text,
        "PathoFMPred naming is inconsistent")
require("DINOv2" in main_text, "Foundation-model introduction does not mention DINOv2")
require("TCGA-AA-A01F" in main_text and "TCGA-A6-A56B" in main_text,
        "The two COAD examples are missing from the main manuscript")
require("reference rank, not probability" in combined.lower(),
        "Binary rank warning is missing")
require("TITANPred" not in combined, "Obsolete TITANPred name remains")
require("revision-added" not in main_text.lower(), "Revision-history language remains in the manuscript")
require("inferentially qualified" not in main_text.lower(), "Overstated inferential terminology remains")
require("1,933" not in main_text and "1,507" not in main_text,
        "Stale matched-atlas task counts remain in the manuscript")
require("1,933" not in supp_text and "2,073" not in supp_text,
        "Stale task-universe counts remain in the Supplement")
require("1,933" not in response_text and "2,073" not in response_text,
        "Stale task-universe counts remain in the response")
require("1-10-component" not in combined and "1–10-component" not in combined,
        "Stale 1 to 10 primary component wording remains")
require("163/243" not in main_text and "68/243" not in main_text,
        "Stale biological breadth counts remain in the manuscript")
require("160/243" in main_text and "65/243" in main_text,
        "Current direct-genomic breadth counts are missing")
require("Figure 3. Foundation-model leadership" in main_text and "960 cross-modal" in main_text,
        "Foundation-model leadership scope is not synchronized")
require("TITAN, Giga-SSL and Prov-GigaPath crossed the Q² threshold in 633, 351 and 430" in main_text,
        "Abstract representation order or continuous counts are inconsistent")
require("TITAN returned eight endpoints" in main_text and "seven each" in main_text,
        "COAD binary model counts are not synchronized")
require("PI3K pathway" not in main_text and "nine endpoints" not in main_text,
        "Obsolete COAD binary output remains in the manuscript")
require("GPL-3.0-or-later companion analysis repository" in supp_text,
        "Analysis-repository license statement is missing")
require("PathoFMPred contributor-authored source code and documentation are released under the MIT License" in supp_text,
        "PathoFMPred MIT source-code statement is missing")
require("TITAN fitted collection is excluded from the public repository" in supp_text,
        "TITAN redistribution boundary is missing")
require("—" not in combined, "Em dash remains in the submission documents")


def section_paragraphs(document: Document, start: str, end: str) -> list[str]:
    values = []
    active = False
    for paragraph in document.paragraphs:
        if paragraph.text.strip() == start:
            active = True
            continue
        if paragraph.text.strip() == end:
            break
        if active:
            values.append(paragraph.text)
    return values


main_methods = "\n".join(section_paragraphs(main, "Methods", "Results"))
supp_methods = "\n".join(section_paragraphs(supp, "Supplementary Methods", "Table S1. Analysis coverage and evidence layers"))
require(not re.search(r"\b(?:We|we|Our|our)\b", main_methods),
        "Active first-person wording remains in the main Methods")
require(not re.search(r"\b(?:We|we|Our|our)\b", supp_methods),
        "Active first-person wording remains in the Supplementary Methods")


def parse_citations(value: str, maximum: int) -> list[int]:
    found = []
    for raw in re.findall(r"\[([0-9][0-9,\- ]*)\]", value):
        group = []
        for token in raw.split(","):
            token = token.strip()
            if "-" in token:
                start, finish = map(int, token.split("-", 1))
                group.extend(range(start, finish + 1))
            else:
                group.append(int(token))
        if group and all(number <= maximum for number in group):
            found.extend(group)
    return found


reference_heading = next(i for i, p in enumerate(main.paragraphs) if p.text.strip() == "References")
reference_numbers = []
for paragraph in main.paragraphs[reference_heading + 1:]:
    match = re.match(r"^(\d+)\.\s", paragraph.text)
    if match:
        reference_numbers.append(int(match.group(1)))
require(reference_numbers == list(range(1, len(reference_numbers) + 1)),
        "Bibliography is not consecutively numbered")
first_appearance = []
for paragraph in main.paragraphs[:reference_heading]:
    for number in parse_citations(paragraph.text, len(reference_numbers)):
        if number not in first_appearance:
            first_appearance.append(number)
for paragraph in supp.paragraphs:
    for number in parse_citations(paragraph.text, len(reference_numbers)):
        if number not in first_appearance:
            first_appearance.append(number)
for table in supp.tables:
    for row in table.rows:
        for cell in row.cells:
            for number in parse_citations(cell.text, len(reference_numbers)):
                if number not in first_appearance:
                    first_appearance.append(number)
require(first_appearance == reference_numbers,
        f"References are not numbered by first appearance: {first_appearance}")

table_captions = [p.text for p in main.paragraphs if re.match(r"^Table \d+\.", p.text)]
figure_captions = [p.text for p in main.paragraphs if re.match(r"^Figure \d+\.", p.text)]
require([int(re.match(r"Table (\d+)", x).group(1)) for x in table_captions] == list(range(1, len(table_captions) + 1)),
        "Main table captions are not sequential")
require([int(re.match(r"Figure (\d+)", x).group(1)) for x in figure_captions] == list(range(1, len(figure_captions) + 1)),
        "Main figure captions are not sequential")

first_supp = []
for paragraph in main.paragraphs:
    for label in re.findall(r"Supplementary Table S(\d+)", paragraph.text):
        if label not in first_supp:
            first_supp.append(label)
require(first_supp == sorted(first_supp, key=int),
        f"Supplementary tables are first cited out of order: {first_supp}")

for report in (
    "Additional_file_2_COAD_example_A_PathoFMPred_report.pdf",
    "Additional_file_3_COAD_example_B_PathoFMPred_report.pdf",
):
    require((OUT / report).exists() and (OUT / report).stat().st_size > 10_000,
            f"Missing or empty additional report: {report}")

print("Document audit passed for the synchronized main manuscript, Supplement, response, cover letter and patient reports.")
