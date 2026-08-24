#!/usr/bin/env python3
"""Build a data-aware, fresh JTM-style review of the revised manuscript."""
from __future__ import annotations

import csv
from datetime import date
from pathlib import Path

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor

ROOT = Path(__file__).resolve().parents[1]
TABLES = ROOT / "results" / "tables"
OUTPUT = ROOT / "manuscript" / "reviewer_report_JTM.docx"
BLUE = RGBColor(31, 77, 120)
MUTED = RGBColor(90, 90, 90)
BLACK = RGBColor(0, 0, 0)


def read_rows(name):
    with (TABLES / name).open(encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def set_font(run, size=11, bold=False, italic=False, color=BLACK):
    run.font.name = "Calibri"
    fonts = run._element.get_or_add_rPr().rFonts
    fonts.set(qn("w:ascii"), "Calibri")
    fonts.set(qn("w:hAnsi"), "Calibri")
    run.font.size = Pt(size)
    run.bold = bold
    run.italic = italic
    run.font.color.rgb = color


def shade(paragraph, fill):
    shd = OxmlElement("w:shd")
    shd.set(qn("w:fill"), fill)
    paragraph._p.get_or_add_pPr().append(shd)


def add_body(doc, text, lead=None):
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(6)
    p.paragraph_format.line_spacing = 1.10
    if lead and text.startswith(lead):
        set_font(p.add_run(lead), bold=True)
        set_font(p.add_run(text[len(lead):]))
    else:
        set_font(p.add_run(text))
    return p


def add_heading(doc, text, level=1):
    p = doc.add_paragraph(style=f"Heading {level}")
    p.paragraph_format.keep_with_next = True
    p.add_run(text)
    return p


def add_page_field(paragraph):
    run = paragraph.add_run()
    begin = OxmlElement("w:fldChar")
    begin.set(qn("w:fldCharType"), "begin")
    instr = OxmlElement("w:instrText")
    instr.set(qn("xml:space"), "preserve")
    instr.text = " PAGE "
    separate = OxmlElement("w:fldChar")
    separate.set(qn("w:fldCharType"), "separate")
    text = OxmlElement("w:t")
    text.text = "1"
    end = OxmlElement("w:fldChar")
    end.set(qn("w:fldCharType"), "end")
    run._r.extend([begin, instr, separate, text, end])
    set_font(run, size=9, color=MUTED)


continuous = read_rows("continuous_screen.csv")
binary = read_rows("binary_screen.csv")
highlighted = read_rows("highlighted_model_performance.csv")
mutation_coverage = read_rows("mutation_coverage_audit.csv")
slide_audit = read_rows("patient_slide_multiplicity_by_cancer.csv")
participant_characteristics = read_rows("participant_characteristics_by_cancer.csv")
ridge_summary = read_rows("pls_vs_ridge_summary.csv")
binary_ridge_summary = next(
    r for r in ridge_summary if r["outcome_type"] == "binary"
)
participant_overall = next(
    r for r in participant_characteristics if r["tumor_type"] == "Overall"
)

screen_c = [r for r in continuous if r["tier"] in ("A", "B")]
screen_b = [r for r in binary if r["tier"] in ("A", "B")]
global_c = [r for r in screen_c if float(r["q_value_global"]) < 0.05]
global_mut = [
    r for r in screen_b
    if r["family"] == "driver_mutation" and float(r["q_value_global"]) < 0.05
]
n_mc3_profiled = sum(int(r["matched_profiled_patients"]) for r in mutation_coverage)
n_mc3_missing = sum(int(r["embedding_patients_without_mc3_profile"]) for r in mutation_coverage)
n_multi = sum(int(r["multi_slide_patients"]) for r in slide_audit)

doc = Document()
section = doc.sections[0]
section.top_margin = section.bottom_margin = Inches(0.9)
section.left_margin = section.right_margin = Inches(1.0)
styles = doc.styles
styles["Normal"].font.name = "Calibri"
styles["Normal"].font.size = Pt(11)
for name, size in (("Heading 1", 16), ("Heading 2", 13), ("Heading 3", 11.5)):
    style = styles[name]
    style.font.name = "Calibri"
    style.font.size = Pt(size)
    style.font.bold = True
    style.font.color.rgb = BLUE
    style.paragraph_format.keep_with_next = True

header = section.header.paragraphs[0]
set_font(header.add_run("Independent internal review | Journal of Translational Medicine"),
         size=9, color=MUTED)
footer = section.footer.paragraphs[0]
footer.alignment = WD_ALIGN_PARAGRAPH.RIGHT
set_font(footer.add_run("Page "), size=9, color=MUTED)
add_page_field(footer)

p = doc.add_paragraph()
set_font(p.add_run("REVIEWER REPORT"), size=23, bold=True, color=BLUE)
p = doc.add_paragraph()
set_font(
    p.add_run(
        "A systematic patient-level benchmark and reusable model resource for "
        "molecular and immune prediction from pretrained TITAN whole-slide "
        "representations across 32 TCGA cancers"
    ), size=14, color=MUTED
)
for label, value in (
    ("Target journal", "Journal of Translational Medicine — Molecular Pathology"),
    ("Article type", "Research article"),
    ("Review basis", "Fresh review of the revised manuscript, supplement and reproducibility materials"),
    ("Recommendation", "Major revision; consider only under an explicit computational-resource framing unless external validation is added"),
    ("Date", date.today().strftime("%d %B %Y")),
):
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(2)
    set_font(p.add_run(label + ": "), bold=True)
    set_font(p.add_run(value))

callout = doc.add_paragraph()
callout.paragraph_format.space_before = Pt(12)
callout.paragraph_format.space_after = Pt(10)
callout.paragraph_format.left_indent = Inches(0.12)
callout.paragraph_format.right_indent = Inches(0.12)
shade(callout, "EEF4F8")
set_font(callout.add_run("Overall assessment. "), bold=True, color=BLUE)
set_font(callout.add_run(
    "This is a carefully reconstructed, patient-level TCGA benchmark and research-software resource. "
    "The revised work addresses the major scientific concerns that would "
    "otherwise prevent interpretation: multiple slides are aggregated before "
    "validation; molecular missingness is not labelled wild type; binary "
    "models use PLS–LDA; continuous and binary performance is reported with "
    "uncertainty; multiplicity is shown both within cancer and across cancers; "
    "and the absence of independent external validation is explicit. The revised wording no longer "
    "presents internal TCGA estimates as translational evidence. Nevertheless, independent validation "
    "remains the decisive missing element for publication as a translational prediction study."
))

add_heading(doc, "Confidential comments to the editor", 1)
add_body(doc,
    "The manuscript fits the Molecular Pathology remit as a reproducible study "
    "of image-derived molecular and immune signals in human tumours. Its main "
    "contribution is a transparent endpoint-by-endpoint benchmark using a fixed "
    "pretrained representation, complete negative reporting and portable fitted linear models. "
    "The authors appropriately refrain from clinical claims and label every value as an internally "
    "derived TCGA estimate. Without an independent cohort, the work should be evaluated as a "
    "computational pathology resource rather than a translational prediction study."
)

add_heading(doc, "Comments to the authors", 1)

add_heading(doc, "1. Scientific design and analysis", 2)
add_body(doc,
    f"The patient is now the analysis unit and {n_multi:,} patients with multiple "
    "eligible slides are pooled before outcome matching and fold assignment. "
    "The first-slide sensitivity is an appropriate patient-aggregation check. "
    "Tissue-source-site sensitivity is now treated separately as a central finding. Mutation denominators are restricted to "
    f"{n_mc3_profiled:,} MC3-profiled patients, while {n_mc3_missing:,} patients "
    "without a matched profile remain missing; the nine retained protein-altering "
    "variant classes are now explicit and audited. The source-level aliquot and "
    "fusion-coverage audits make the outcome construction reproducible. "
    f"The TCGA Clinical Data Resource now supplies descriptive characteristics "
    f"for {int(participant_overall['cdr_matched']):,} matched participants, "
    "including age, recorded gender, race and broad stage overall and by cancer."
)
add_body(doc,
    "No additional analysis requested. The manuscript should retain the exact "
    "wild-type, fusion-negative and patient-aggregation definitions during copyediting, "
    "and should not imply that descriptive demographics constitute subgroup model validation.",
    lead="No additional analysis requested."
)

add_heading(doc, "2. Multiplicity and interpretation", 2)
add_body(doc,
    f"The final screen reports {len(screen_c):,} continuous and {len(screen_b):,} "
    "binary within-cancer candidates. The stricter across-cancer family correction "
    f"retains {len(global_c):,} continuous and {len(global_mut):,} mutation pairs. "
    "The 999-permutation target, finite-p correction, conservative sequential "
    "stopping and explicit global sensitivity are transparent for an exploratory benchmark. "
    "The manuscript appropriately acknowledges that the minimum empirical p-value "
    "of 0.001 limits attainable q-values in large global families, so global "
    "non-passage must not be read as evidence of no biological signal. "
    "The revised higher-effect/moderate-effect/screen-negative language is preferable "
    "to presenting internal tiers as clinical evidence grades."
)
add_body(doc,
    "No additional analysis requested. Preserve the numerical distinction between "
    "within-cancer and across-cancer results in the abstract and conclusions.",
    lead="No additional analysis requested."
)

add_heading(doc, "3. Performance reporting and research-use provenance", 2)
add_body(doc,
    f"The {len(highlighted):,} highlighted models report sensitivity, specificity, "
    "balanced accuracy and AUROC for binary outcomes and Q², RMSE and Spearman "
    "correlation for continuous outcomes, with patient-cluster bootstrap intervals. "
    "The Discussion correctly clarifies that these intervals are conditional on "
    "endpoint selection in the same TCGA benchmark and do not remove winner's-curse "
    "optimism or estimate external performance. "
    "The observed-versus-predicted figure is useful. Model artifacts record ordered "
    "feature schema, checksums, training ranges, pooling, endpoint transformations, "
    "output units, class coding, priors, decision behaviour, calibration status "
    "and external-validation status. The registry also reports the exact fastPLS "
    "commit, computation backend and exclusive seeded rSVD configuration. Removal of training latent-score and "
    "fitted-value rows strengthens the portability claim."
)
add_body(doc,
    "No additional analysis requested. Continue to describe LDA scores as uncalibrated "
    "and all fitted objects as research-only TCGA models.",
    lead="No additional analysis requested."
)

add_heading(doc, "4. Tissue-source-site sensitivity and confounding", 2)
add_body(doc,
    "The revised manuscript now makes the site result visible rather than reducing it to a median robustness statistic. "
    "Main Figure 6 shows every target, the largest attenuations and the new within-cancer submitting-site classifiers; "
    "Main Table 3 reports grouped performance beside highlighted models. Overall, 83/323 screen-positive models (25.7%) "
    "fell below their original effect threshold. READ–APC and COAD–APC declined to balanced accuracies 0.495 and 0.543. "
    "The public analysis registry and inference output expose the grouped metric, delta, site count, threshold-retention "
    "status and prominent warning for every model. The complete fold audit reports patients, sites and class counts in "
    "all 1,613 outer folds and confirms that inner component selection also kept tissue-source sites intact."
)
add_body(doc,
    "The dedicated repeated nested analysis predicted tissue-source site from TITAN representations in 27/32 evaluable "
    "cancers, with median multiclass macro balanced accuracy 0.628. This quantifies substantial confounding potential. "
    "The manuscript appropriately calls the endpoint analysis 'TCGA tissue-source-site-grouped internal validation' and "
    "does not interpret retained performance as proof of scanner, laboratory or institutional transportability. Tissue-source "
    "site remains an imperfect proxy, and smaller grouped folds can account for part—but not all—of the attenuation."
)

add_heading(doc, "5. Symmetric binary PLS–ridge comparison", 2)
add_body(doc,
    "The revised 12-model binary comparison removes the earlier operating-rule advantage given to ridge. "
    "PLS–LDA and ridge now use identical outer partitions and identical inner partitions. Within each outer "
    "training set, both operating thresholds are selected from method-specific inner out-of-fold scores by "
    "maximising balanced accuracy. Threshold-independent AUROC is the primary binary algorithm-comparison "
    f"metric: the median ridge-minus-PLS difference is {float(binary_ridge_summary['median_delta_ridge_minus_pls']):.3f} "
    f"(IQR {float(binary_ridge_summary['q1_delta']):.3f} to {float(binary_ridge_summary['q3_delta']):.3f}); "
    "one endpoint favours ridge and 11 are uncertain. Under symmetric thresholding, the median "
    f"balanced-accuracy difference is {float(binary_ridge_summary['median_secondary_delta_ridge_minus_pls']):.3f} "
    f"(IQR {float(binary_ridge_summary['q1_secondary_delta']):.3f} to {float(binary_ridge_summary['q3_secondary_delta']):.3f}); "
    "again one endpoint favours ridge and 11 are uncertain. The primary atlas appropriately retains its "
    "prespecified observed-prior PLS–LDA rule and is distinguished from this conditional method benchmark."
)
add_body(doc,
    "No additional algorithm-comparison correction is requested. Table S10e should retain both AUROC and the "
    "symmetrically thresholded balanced accuracy, and the manuscript should not interpret this selected 12-model "
    "subset as evidence of atlas-wide superiority for either method.",
    lead="No additional algorithm-comparison correction is requested."
)

add_heading(doc, "6. Relation to prior work and translational positioning", 2)
add_body(doc,
    "The expanded review now covers mutation, MSI, gene expression, continuous "
    "biomarkers, fusions, homologous-recombination deficiency and tumour-microenvironment "
    "prediction, and it distinguishes internal current metrics from prior external "
    "AUROCs and correlations. The manuscript correctly documents that TCGA was "
    "excluded from TITAN's Mass-340K pretraining but used in TITAN's downstream "
    "evaluation. It is therefore accurate to call this a secondary systematic TCGA "
    "benchmark rather than independent validation."
)
add_body(doc,
    "The authors now document that CPTAC-UCEC is a feasible future cohort but that its "
    "whole-slide archive requires de novo TITAN extraction. They lock UCEC TP53 mutation, "
    "genome doubling and continuous aneuploidy score before inspecting external data, with "
    "artifact hashes, no-refitting rules and mandatory reporting of failures. This is useful "
    "prospective discipline, but it is not external validation evidence."
)

add_heading(doc, "7. Reproducibility and model redistribution", 2)
add_body(doc,
    "The reproducibility resource is split between the public analysis repository and a "
    "separate GPL-3 TITANPred R package. The package contains all 323 fitted research models, "
    "their SHA-256 registry, repeated out-of-fold reference distributions, cancer-vector "
    "inference interface and HTML/PDF research-software template. The package repository is "
    "currently private, and the manuscript now states this rather than claiming public release. The "
    "artifacts contain learned parameters and training-range summaries but no patient-level "
    "training rows. This materially strengthens the portability and transparency claim."
)
add_body(doc,
    "Required before submission: create a versioned release and persistent DOI for the public "
    "analysis repository. If fitted-model redistribution is authorised, document the model-package "
    "access terms and archive it separately; otherwise retain the private/access-controlled status "
    "throughout the manuscript. Keep the research-only and no-external-validation notices and cite "
    "the upstream TITAN work and feature source in the package documentation.",
    lead="Required before submission:"
)

add_heading(doc, "8. Administrative completion", 2)
add_body(doc,
    "Required before submission: replace the remaining placeholders for funding, "
    "competing interests and author contributions; confirm the institutional ethics/waiver "
    "wording. Aamilah Ismail and Martin Ocharo are now the shared co-first authors, "
    "with Martin Ocharo second in the author order and assigned to affiliations 1 and 2. "
    "Brendon Price is included in the middle of the author list with the Division of "
    "Anatomical Pathology, University of Cape Town and National Health Laboratory Service "
    "affiliation. Ekene Emmanuel Nweke's University of the Witwatersrand affiliation is "
    "included. Silvano Piazza and Dinesh Gupta are listed immediately before Stefano "
    "Cacciatore. Silvano Piazza has dual affiliations with the ICGEB Computational Biology "
    "Group in Trieste and the Bioinformatics Facility, CIBIO, University of Trento; Dinesh "
    "Gupta has the ICGEB New Delhi affiliation. "
    "Email addresses for Martin Ocharo, Brendon Price, Ekene Emmanuel Nweke, Silvano "
    "Piazza and Dinesh Gupta were not supplied. The current author list contains Aamilah "
    "Ismail, Martin Ocharo, Moussa Kassim, Dalia Ahmed, Brendon Price, Dupe Ojo, Ekene "
    "Emmanuel Nweke, Silvano Piazza, Dinesh Gupta and Stefano Cacciatore."
)

add_heading(doc, "Minor presentation points", 1)
for title, body in (
    ("Reporting checklist", "The TRIPOD+AI item-to-location map in Supplementary Table S12 should accompany the submission."),
    ("Fusion caveat", "Keep the technical-coverage caveat for fusion-negative status and fusion burden."),
    ("Figures", "Figure 1 is no longer clipped, and Figure 4A now shows the strongest primary continuous prediction with explicit held-out metrics. These corrected production figures should be retained."),
):
    add_heading(doc, title, 3)
    add_body(doc, body)

add_heading(doc, "Strengths", 1)
for body in (
    "Patient-first aggregation and validation prevent multiple-slide leakage.",
    "Wild type, molecular missingness, fusion coverage and aliquot aggregation are auditable.",
    "The benchmark includes immune and inflammatory features as well as mutations, pathways, MSI, aneuploidy and fusions.",
    "Negative and ineligible endpoints are preserved rather than selectively omitted.",
    "PLS1–PLS2 comparison is appropriately secondary, with LDA preferred for binary endpoints.",
    "The literature discussion reports that 38 of 41 screen-positive mutation pairs had prior support and avoids broad endpoint-novelty claims.",
):
    add_body(doc, "• " + body)

add_heading(doc, "Recommended editorial decision", 1)
decision = doc.add_paragraph()
shade(decision, "E8EEF5")
set_font(decision.add_run("MAJOR REVISION / RESOURCE FRAMING"), size=12, bold=True, color=BLUE)
add_body(doc,
    "The scientific analysis may be considered as a TCGA patient-level computational pathology benchmark and research-software resource. "
    "It is not yet supported as a translational prediction study because no independent cohort has been evaluated. "
    "The revised framing, locked future protocol and complete internal reporting are appropriate, but they do not replace external evidence. "
    "Declarations and author metadata also remain to be completed."
)

add_heading(doc, "Review standards consulted", 1)
add_body(doc,
    "Warren S. Molecular Pathology. J Transl Med. 2024;22:91. "
    "https://doi.org/10.1186/s12967-024-04868-7"
)
add_body(doc,
    "Collins GS, et al. TRIPOD+AI statement. BMJ. 2024;385:e078378. "
    "https://doi.org/10.1136/bmj-2023-078378"
)

doc.core_properties.title = "Fresh reviewer report — TITAN TCGA benchmark and model resource"
doc.core_properties.subject = "Journal of Translational Medicine-style internal peer review"
doc.core_properties.author = "Internal scientific review"
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
doc.save(OUTPUT)
print(OUTPUT)
