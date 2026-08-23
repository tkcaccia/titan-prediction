#!/usr/bin/env python3
"""Fail closed on structural requirements of the final JTM DOCX package."""
from __future__ import annotations

import re
from pathlib import Path

from docx import Document


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "manuscript"
EXPECTED = {
    "manuscript_JTM_patient_level_TITAN.docx",
    "supplementary_material_JTM.docx",
    "response_to_reviewer_JTM.docx",
    "reviewer_report_JTM.docx",
}
AUTHORS = (
    "Aamilah Ismail",
    "Martin Ocharo",
    "Moussa Kassim",
    "Dalia Ahmed",
    "Brendon Price",
    "Dupe Ojo",
    "Ekene Emmanuel Nweke",
    "Silvano Piazza",
    "Dinesh Gupta",
    "Stefano Cacciatore",
)
REMOVED = ("Alessia Vignoli", "Leonardo Tenori", "CERM", "University of Florence")


def require(ok: bool, message: str) -> None:
    if not ok:
        raise RuntimeError(message)


def full_text(document: Document) -> str:
    chunks = [p.text for p in document.paragraphs]
    for table in document.tables:
        for row in table.rows:
            chunks.extend(cell.text for cell in row.cells)
    return "\n".join(chunks)


found = {p.name for p in OUT.glob("*.docx") if not p.name.startswith("~$")}
require(found == EXPECTED, f"Expected exactly four final DOCX files; found {sorted(found)}")

documents = {name: Document(OUT / name) for name in EXPECTED}
texts = {name: full_text(document) for name, document in documents.items()}
combined = "\n".join(texts.values())
for removed in REMOVED:
    require(removed not in combined, f"Removed author/affiliation remains in DOCX output: {removed}")

main_name = "manuscript_JTM_patient_level_TITAN.docx"
main = documents[main_name]
main_text = texts[main_name]
for author in AUTHORS:
    require(author in main_text, f"Required author missing from manuscript: {author}")
author_positions = [main_text.index(author) for author in AUTHORS]
require(
    author_positions == sorted(author_positions),
    "Author order is inconsistent with the approved ten-author sequence",
)
require(
    "Aamilah Ismail3,*" in main_text and "Martin Ocharo1,2,*" in main_text,
    "Shared co-first authorship markers are missing for Aamilah Ismail and Martin Ocharo",
)
require(
    "Department of Surgery, Faculty of Health Sciences, University of the Witwatersrand, "
    "Johannesburg, Gauteng, South Africa" in main_text,
    "Ekene Emmanuel Nweke's affiliation is missing",
)
require(
    "Division of Anatomical Pathology, University of Cape Town and National Health "
    "Laboratory Service, Observatory, Cape Town, South Africa" in main_text,
    "Brendon Price's affiliation is missing",
)
require(
    "Computational Biology Group, International Centre for Genetic Engineering and "
    "Biotechnology (ICGEB), Trieste, Italy" in main_text,
    "Silvano Piazza's ICGEB affiliation is missing",
)
require(
    "Bioinformatics Facility, Department of Cellular, Computational and Integrative "
    "Biology - CIBIO, University of Trento, Trento, Italy" in main_text,
    "Silvano Piazza's CIBIO affiliation is missing",
)
require(
    "Translational Bioinformatics Group, International Centre for Genetic Engineering "
    "and Biotechnology (ICGEB), Aruna Asaf Ali Marg, New Delhi 110067, India" in main_text,
    "Dinesh Gupta's affiliation is missing",
)
require(
    "† Corresponding author: Stefano Cacciatore" in main_text,
    "Sole corresponding-author statement is missing",
)
require(
    "Silvano Piazza6,8" in main_text,
    "Silvano Piazza's dual-affiliation markers are missing",
)
for label in (
    "Additional file 2 (.pdf): COAD example A (TCGA-AA-A01F) TITANPred single-sample report",
    "Additional file 3 (.pdf): COAD example B (TCGA-AA-3972) TITANPred single-sample report",
):
    require(label in main_text, f"Separate supplementary report is not declared: {label}")
for pdf_name in (
    "Additional_file_2_COAD_example_A_TITANPred_report.pdf",
    "Additional_file_3_COAD_example_B_TITANPred_report.pdf",
):
    pdf_path = OUT / pdf_name
    require(pdf_path.is_file(), f"Separate supplementary PDF is missing: {pdf_name}")
    require(pdf_path.read_bytes().startswith(b"%PDF"), f"Invalid PDF signature: {pdf_name}")
for heading in (
    "Abstract",
    "Background",
    "Methods",
    "Results",
    "Discussion",
    "Conclusions",
    "Abbreviations",
    "Declarations",
    "References",
):
    require(heading in main_text, f"Required manuscript section missing: {heading}")

paragraphs = [p.text.strip() for p in main.paragraphs]
abstract_start = paragraphs.index("Abstract") + 1
keywords_index = next(
    i for i in range(abstract_start, len(paragraphs))
    if paragraphs[i].startswith("Keywords:")
)
abstract = " ".join(paragraphs[abstract_start:keywords_index])
abstract_words = re.findall(r"\b[\w²×–-]+\b", abstract, flags=re.UNICODE)
require(len(abstract_words) <= 350, f"Abstract has {len(abstract_words)} words (>350)")
keyword_count = len([x for x in paragraphs[keywords_index][9:].split(";") if x.strip()])
require(3 <= keyword_count <= 10, f"Keyword count is {keyword_count}; expected 3–10")
require(len(main.inline_shapes) >= 6, "Main manuscript contains fewer than six embedded figures")
for forbidden in (
    "IRLBA",
    "Liver and pancreatic cancer examples",
    "Previously reported and atlas-nominated predictors",
    "Practical contribution of the PLS framework",
    "discovery atlas",
):
    require(forbidden.lower() not in main_text.lower(), f"Removed manuscript text remains: {forbidden}")
require("frozen" not in main_text.lower(), "Ambiguous 'frozen' terminology remains")
for required_revision in (
    "A systematic patient-level benchmark and reusable model resource",
    "Table 1. Comparison with major pan-cancer histology–molecular prediction studies",
    "12,093 target-specific models for 4,031 multi-omic biomarkers",
    "fixed pretrained representation",
    "tested-negative and sample-size-ineligible results",
    "83/323 models (25.7%) fell below the original effect threshold",
    "PLS was competitive but not uniformly superior",
    "38/41 screen-positive cancer–gene pairs",
    "TCGA out-of-fold score rank (not probability)",
    "Probability calibration was not added",
):
    require(
        required_revision in main_text,
        f"A required audit-driven revision is missing: {required_revision}",
    )
for header in (
    "Q² or Se/Sp (95% CI)",
    "RMSE or BA (95% CI)",
    "Spearman or AUROC (95% CI)",
):
    require(header in main_text, f"Table 3 metric header is missing: {header}")
for header in (
    "Patients; cancers",
    "Representation; patient aggregation",
    "Validation design",
    "Site sensitivity",
    "External validation",
    "Negative/ineligible reporting",
    "Fitted predictors",
):
    require(header in main_text, f"Main-text pan-cancer comparison field is missing: {header}")

supplement = documents["supplementary_material_JTM.docx"]
supplement_text = texts["supplementary_material_JTM.docx"]
for item in (
    "Table S10a. Expanded literature audit",
    "Table S10b. Screen-positive models below the original effect threshold",
    "Table S10c. PLS versus exportable ridge benchmark",
    "Table S12",
    "Figure S1",
    "Figure S2",
    "Machine-readable additional files",
):
    require(item in supplement_text, f"Supplementary item missing: {item}")
require(len(supplement.inline_shapes) >= 2, "Supplement contains fewer than two figures")

for name, text in texts.items():
    require("Error! Reference source not found" not in text, f"Broken Word field in {name}")

print(
    f"Document audit passed: four DOCX files; {len(AUTHORS)}-author manuscript; "
    f"abstract {len(abstract_words)} words; {len(main.inline_shapes)} main figures; "
    f"{len(supplement.inline_shapes)} supplementary figures"
)
