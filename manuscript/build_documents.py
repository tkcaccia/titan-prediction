#!/usr/bin/env python3
"""Build the JTM manuscript, supplement and point-by-point response from results."""
from __future__ import annotations

import csv
import os
import shutil
from collections import Counter, defaultdict
from pathlib import Path

from docx import Document
from docx.enum.section import WD_ORIENT, WD_SECTION
from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT, WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Inches, Pt, RGBColor

ROOT = Path(__file__).resolve().parents[1]
TABLES = ROOT / "results" / "tables"
REFERENCE = ROOT / "data" / "reference"
FIGURES = ROOT / "figures"
OUT = ROOT / "manuscript"
OUT.mkdir(exist_ok=True)
REPO = os.environ.get(
    "TITAN_REPOSITORY_URL", "https://github.com/tkcaccia/titan-prediction"
)
MODEL_REPO = os.environ.get(
    "TITAN_MODEL_REPOSITORY_URL", "https://github.com/tkcaccia/TITANPred"
)
MANUSCRIPT_TITLE = (
    "A systematic patient-level benchmark and reusable model resource for molecular "
    "and immune prediction from pretrained TITAN whole-slide representations across "
    "32 TCGA cancers"
)


def rows(name):
    with (TABLES / name).open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def optional_rows(name):
    path = TABLES / name
    if not path.exists():
        return []
    with path.open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def reference_rows(name):
    with (REFERENCE / name).open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def fnum(x, digits=3):
    try:
        return f"{float(x):.{digits}f}"
    except (TypeError, ValueError):
        return "NA"


def ival(x):
    try:
        return int(float(x))
    except (TypeError, ValueError):
        return 0


def setup(doc, title=None):
    sec = doc.sections[0]
    sec.top_margin = Cm(2.0); sec.bottom_margin = Cm(2.0)
    sec.left_margin = Cm(2.2); sec.right_margin = Cm(2.2)
    styles = doc.styles
    normal = styles["Normal"]
    normal.font.name = "Arial"; normal.font.size = Pt(10.5)
    normal.paragraph_format.space_after = Pt(5)
    normal.paragraph_format.line_spacing = 2.0
    for name, size, color in [("Title", 20, "17365D"), ("Heading 1", 15, "17365D"),
                              ("Heading 2", 12, "2F5597"), ("Heading 3", 10.5, "2F5597")]:
        st = styles[name]; st.font.name = "Arial"; st.font.size = Pt(size)
        st.font.color.rgb = RGBColor.from_string(color); st.font.bold = True
        st.paragraph_format.line_spacing = 2.0
    styles["Caption"].font.name = "Arial"; styles["Caption"].font.size = Pt(9)
    styles["Caption"].font.italic = True
    header = sec.header.paragraphs[0]
    header.text = title or "TITAN patient-level prediction benchmark"
    header.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    header.runs[0].font.size = Pt(8); header.runs[0].font.color.rgb = RGBColor(100, 116, 139)
    footer = sec.footer.paragraphs[0]; footer.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run = footer.add_run("Page ")
    fld = OxmlElement("w:fldSimple"); fld.set(qn("w:instr"), "PAGE")
    run._r.addnext(fld)
    # Journal of Translational Medicine requires continuous line numbering.
    sect_pr = sec._sectPr
    line_numbers = OxmlElement("w:lnNumType")
    line_numbers.set(qn("w:countBy"), "1")
    line_numbers.set(qn("w:restart"), "continuous")
    sect_pr.append(line_numbers)
    return doc


def shade(cell, fill):
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd"); shd.set(qn("w:fill"), fill); tc_pr.append(shd)


def add_table(doc, headers, data, widths=None):
    table = doc.add_table(rows=1, cols=len(headers))
    table.alignment = WD_TABLE_ALIGNMENT.CENTER; table.style = "Table Grid"
    for i, h in enumerate(headers):
        cell = table.rows[0].cells[i]; cell.text = str(h)
        for r in cell.paragraphs[0].runs: r.font.bold = True; r.font.size = Pt(8.5)
    header_pr = table.rows[0]._tr.get_or_add_trPr()
    repeat = OxmlElement("w:tblHeader"); repeat.set(qn("w:val"), "true")
    header_pr.append(repeat)
    for row in data:
        cells = table.add_row().cells
        for i, val in enumerate(row):
            cells[i].text = str(val); cells[i].vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
            for p in cells[i].paragraphs:
                for r in p.runs: r.font.size = Pt(8)
    for row in table.rows:
        row_pr = row._tr.get_or_add_trPr()
        no_split = OxmlElement("w:cantSplit")
        row_pr.append(no_split)
    if widths:
        for row in table.rows:
            for i, width in enumerate(widths): row.cells[i].width = Cm(width)
    doc.add_paragraph()
    return table


def add_figure(doc, filename, caption, width=6.35):
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.add_run().add_picture(str(FIGURES / filename), width=Inches(width))
    c = doc.add_paragraph(caption, style="Caption"); c.alignment = WD_ALIGN_PARAGRAPH.CENTER


def add_landscape_section(doc):
    sec = doc.add_section(WD_SECTION.NEW_PAGE)
    sec.orientation = WD_ORIENT.LANDSCAPE
    sec.page_width = Cm(29.7); sec.page_height = Cm(21.0)
    sec.top_margin = Cm(1.5); sec.bottom_margin = Cm(1.5)
    sec.left_margin = Cm(1.5); sec.right_margin = Cm(1.5)
    line_numbers = OxmlElement("w:lnNumType")
    line_numbers.set(qn("w:countBy"), "1")
    line_numbers.set(qn("w:restart"), "continuous")
    sec._sectPr.append(line_numbers)
    return sec


def add_portrait_section(doc):
    sec = doc.add_section(WD_SECTION.NEW_PAGE)
    sec.orientation = WD_ORIENT.PORTRAIT
    sec.page_width = Cm(21.0); sec.page_height = Cm(29.7)
    sec.top_margin = Cm(2.0); sec.bottom_margin = Cm(2.0)
    sec.left_margin = Cm(2.2); sec.right_margin = Cm(2.2)
    line_numbers = OxmlElement("w:lnNumType")
    line_numbers.set(qn("w:countBy"), "1")
    line_numbers.set(qn("w:restart"), "continuous")
    sec._sectPr.append(line_numbers)
    return sec


def add_labelled(doc, label, text):
    p = doc.add_paragraph(); r = p.add_run(label + " "); r.bold = True; p.add_run(text)


cohort = rows("patient_cohort_summary.csv")
cohort_rows = rows("patient_cohort_summary.csv")
cohort_patient = cohort_rows
continuous = rows("continuous_screen.csv")
binary = rows("binary_screen.csv")
site_c = rows("continuous_site_grouped_sensitivity.csv")
site_b = rows("binary_site_grouped_sensitivity.csv")
pool_c = rows("continuous_slide_pooling_sensitivity.csv")
pool_b = rows("binary_slide_pooling_sensitivity.csv")
pls2 = rows("pls1_vs_pls2_inflammation_summary.csv")
lit = rows("prior_mutation_literature_pair_summary.csv")
lit_accuracy = rows("prior_mutation_accuracy_comparison.csv")
mutation_novelty = rows("supported_mutation_novelty.csv")
mutation_literature_audit = rows("supported_mutation_literature_audit.csv")
site_retention_summary = rows("site_grouped_retention_summary.csv")
site_threshold_failures = rows("site_grouped_models_below_effect_threshold.csv")
ridge_comparison = rows("pls_vs_ridge_highlighted_models.csv")
external_locked_targets = reference_rows("external_validation_locked_targets.csv")
ridge_summary = rows("pls_vs_ridge_summary.csv")
highlighted = optional_rows("highlighted_model_performance.csv")
slide_coverage = optional_rows("slide_report_coverage_audit.csv")
slide_multiplicity = optional_rows("patient_slide_multiplicity_by_cancer.csv")
mutation_coverage = optional_rows("mutation_coverage_audit.csv")
mutation_eligibility = optional_rows("mutation_target_eligibility_audit.csv")
molecular_coverage = optional_rows("molecular_source_coverage_audit.csv")
participant_characteristics = optional_rows("participant_characteristics_by_cancer.csv")
coad_examples = optional_rows("coad_package_examples.csv")
coad_example_predictions = optional_rows("coad_package_example_predictions.csv")
literature_landscape = []
with (ROOT / "data" / "reference" / "prior_histology_model_landscape.csv").open(
    encoding="utf-8-sig", newline=""
) as f:
    literature_landscape = list(csv.DictReader(f))
with (ROOT / "data" / "reference" / "pan_cancer_benchmark_comparison.csv").open(
    encoding="utf-8-sig", newline=""
) as f:
    pan_cancer_comparison = list(csv.DictReader(f))
with (ROOT / "data" / "reference" / "tripod_ai_reporting_map.csv").open(
    encoding="utf-8-sig", newline=""
) as f:
    tripod_map = list(csv.DictReader(f))

def tier_counts(data):
    ans = defaultdict(Counter)
    for r in data: ans[r["family"]][r["tier"]] += 1
    return ans


ctier = tier_counts(continuous); btier = tier_counts(binary)
supported_c = [r for r in continuous if r["tier"] in ("A", "B")]
supported_b = [r for r in binary if r["tier"] in ("A", "B")]
coad_supported_c = [r for r in supported_c if r["tumor_type"] == "COAD"]
coad_supported_b = [r for r in supported_b if r["tumor_type"] == "COAD"]
global_supported_c = [r for r in supported_c if float(r["q_value_global"]) < 0.05]
global_supported_b = [r for r in supported_b if float(r["q_value_global"]) < 0.05]
global_mutation_b = [r for r in global_supported_b if r["family"] == "driver_mutation"]
top_c = sorted(supported_c, key=lambda r: float(r["q2"]), reverse=True)
top_b = sorted(supported_b, key=lambda r: float(r["balanced_accuracy"]), reverse=True)
global_abstract_text = (
    f'{len(global_supported_c)} continuous and {len(global_mutation_b)} cancer–mutation '
    f'pairs passed the stricter across-cancer correction'
)

if highlighted:
    abstract_continuous = next(
        (r for r in highlighted if r.get("outcome_type") == "continuous"), None
    )
    abstract_binary = next(
        (r for r in highlighted if r.get("outcome_type") == "binary"), None
    )
else:
    abstract_continuous = abstract_binary = None

if abstract_continuous and abstract_binary:
    abstract_metric_text = (
        f'{abstract_continuous["tumor_type"]}–{abstract_continuous["endpoint"]} '
        f'(Q² {fnum(abstract_continuous.get("q2"))}, 95% bootstrap interval '
        f'{fnum(abstract_continuous.get("q2_ci_low"))}–{fnum(abstract_continuous.get("q2_ci_high"))}; RMSE '
        f'{fnum(abstract_continuous.get("rmse"))}, Spearman '
        f'{fnum(abstract_continuous.get("spearman"))}) and '
        f'{abstract_binary["tumor_type"]}–{abstract_binary["endpoint"]} '
        f'(sensitivity {fnum(abstract_binary.get("sensitivity"))}, specificity '
        f'{fnum(abstract_binary.get("specificity"))}, balanced accuracy '
        f'{fnum(abstract_binary.get("balanced_accuracy"))}, 95% bootstrap interval '
        f'{fnum(abstract_binary.get("balanced_accuracy_ci_low"))}–{fnum(abstract_binary.get("balanced_accuracy_ci_high"))}; AUROC '
        f'{fnum(abstract_binary.get("auc"))})'
    )
else:
    abstract_metric_text = (
        f'{top_c[0]["tumor_type"]}–{top_c[0]["endpoint"]} '
        f'(Q² {fnum(top_c[0]["q2"])}) and '
        f'{top_b[0]["tumor_type"]}–{top_b[0]["endpoint"]} '
        f'(balanced accuracy {fnum(top_b[0]["balanced_accuracy"])})'
    )

meta = rows("patient_cohort_summary.csv")
# The summary CSV contains one row per patient. Recompute cohort totals here.
n_patients = len(meta); n_slides = sum(ival(r.get("n_slides")) for r in meta)
n_multi = sum(ival(r.get("n_slides")) > 1 for r in meta)
n_cancers = len({r.get("tumor_type") for r in meta if r.get("tumor_type")})
n_missing_cancer = sum(not r.get("tumor_type") for r in meta)
n_exact_reports = sum(ival(r.get("exact_report_matched_slides")) for r in slide_coverage)
n_unmatched_reports = sum(ival(r.get("unmatched_slides")) for r in slide_coverage)
n_multiple_samples = sum(ival(r.get("patients_with_multiple_primary_sample_barcodes")) for r in slide_multiplicity)
n_mc3_profiled = sum(ival(r.get("matched_profiled_patients")) for r in mutation_coverage)
n_mc3_missing = sum(ival(r.get("embedding_patients_without_mc3_profile")) for r in mutation_coverage)
n_mutation_eligible = sum(r.get("eligibility") == "eligible" for r in mutation_eligibility)
n_mutation_ineligible = len(mutation_eligibility) - n_mutation_eligible
participant_overall = next(
    (r for r in participant_characteristics if r.get("tumor_type") == "Overall"),
    {},
)
source_coverage_summary = []
for source in sorted({r.get("source") for r in molecular_coverage if r.get("source")}):
    sr = [r for r in molecular_coverage if r.get("source") == source]
    source_coverage_summary.append((
        source,
        sum(ival(r.get("cohort_patients")) for r in sr),
        sum(ival(r.get("covered_patients")) for r in sr),
        sum(ival(r.get("missing_patients")) for r in sr),
        sum(ival(r.get("patients_with_multiple_primary_aliquots")) for r in sr),
        max([ival(r.get("maximum_primary_aliquots")) for r in sr] or [0]),
        sr[0].get("aggregation_rule", ""),
    ))

families = {
    "thorsson": "Thorsson immune/genomic-context",
    "aneuploidy": "aneuploidy",
    "fusion": "fusion",
    "microsatellite_instability": "MSI",
    "microsatellite_instability_sensitivity": "strict MSI sensitivity",
    "oncogenic_pathway": "oncogenic pathway",
    "driver_mutation": "cancer-gene mutation",
}

family_table = []
for fam in sorted(set(r["family"] for r in continuous + binary)):
    crows = [r for r in continuous if r["family"] == fam]
    brows = [r for r in binary if r["family"] == fam]
    if crows:
        counts = ctier[fam]
        family_table.append((families.get(fam, fam), "continuous",
                             len(crows), len({r["tumor_type"] for r in crows}),
                             counts["A"], counts["B"], counts["C"]))
    if brows:
        counts = btier[fam]
        family_table.append((families.get(fam, fam), "binary",
                             len(brows), len({r["tumor_type"] for r in brows}),
                             counts["A"], counts["B"], counts["C"]))


def examples(data, metric, n=8, include_family=False):
    ordered = sorted(data, key=lambda r: float(r[metric]), reverse=True)[:n]
    labels = {
        "driver_mutation": "mutation",
        "oncogenic_pathway": "pathway",
        "fusion": "fusion",
        "aneuploidy": "aneuploidy",
        "microsatellite_instability": "MSI",
        "microsatellite_instability_sensitivity": "strict MSI",
    }
    return "; ".join(
        f'{r["tumor_type"]}–{r["endpoint"]}'
        f'{" [" + labels.get(r["family"], r["family"]) + "]" if include_family else ""}'
        f' ({fnum(r[metric])})'
        for r in ordered
    )


def category(tier):
    return {"A": "within-cancer higher effect",
            "B": "within-cancer moderate effect",
            "C": "screen-negative"}.get(tier, tier or "not assessed")


def cancer_result_text(code):
    crows = [r for r in supported_c if r["tumor_type"] == code]
    brows = [r for r in supported_b if r["tumor_type"] == code]
    parts = []
    if crows:
        parts.append(
            f'{len(crows)} continuous candidates: '
            + examples(crows, "q2", min(5, len(crows)))
        )
    else:
        parts.append("no continuous pair was screen-positive")
    if brows:
        parts.append(
            f'{len(brows)} binary candidates: '
            + examples(brows, "balanced_accuracy", min(6, len(brows)),
                       include_family=True)
        )
    else:
        parts.append("no binary pair was screen-positive")
    return "; ".join(parts)


def median(values):
    z = sorted(float(v) for v in values if v not in ("", "NA") and v is not None)
    if not z: return float("nan")
    m = len(z)//2
    return z[m] if len(z)%2 else (z[m-1]+z[m])/2


site_deltas = [r["delta"] for r in site_c + site_b if r.get("feasible") == "TRUE" and r.get("delta")]
pool_deltas = [r["delta_first_minus_mean"] for r in pool_c + pool_b if r.get("delta_first_minus_mean")]
lit_counts = Counter(r["current_status"] for r in lit)
recovered_reports = [r for r in lit_accuracy if r["current_status"].startswith("recovered_tier_")]
prior_supported_mutations = [
    r for r in mutation_literature_audit
    if r["evidence_class"].startswith("previously supported")
]
prior_evaluated_not_supported = [
    r for r in mutation_literature_audit
    if r["evidence_class"].startswith("previously evaluated")
]
not_identified_mutations = [
    r for r in mutation_literature_audit
    if r["evidence_class"].startswith("not identified")
]
site_combined = next(
    (r for r in site_retention_summary if r.get("outcome_type") == "combined"), {}
)
site_failure_examples = sorted(
    site_threshold_failures,
    key=lambda r: float(r.get("site_grouped_metric") or 999),
)[:12]
site_named_keys = [
    ("binary", "READ", "APC"),
    ("binary", "COAD", "APC"),
    ("binary", "PCPG", "Cell Cycle"),
    ("binary", "LIHC", "CTNNB1"),
    ("continuous", "OV", "TCR Shannon"),
    ("continuous", "COAD", "SNV Neoantigens"),
]
site_named_failures = []
for outcome_type, cancer, endpoint in site_named_keys:
    match = next((
        r for r in site_threshold_failures
        if r.get("outcome_type") == outcome_type
        and r.get("tumor_type") == cancer and r.get("endpoint") == endpoint
    ), None)
    if match:
        site_named_failures.append(match)
ridge_better = [r for r in ridge_comparison if r.get("selected_method") == "ridge"]
pls_better = [r for r in ridge_comparison if r.get("selected_method") == "PLS"]
baseline_uncertain = [
    r for r in ridge_comparison if "difference uncertain" in r.get("selected_method", "")
]


def prior_current_text(records):
    return "; ".join(
        f'{r["cancer"]}–{r["gene"]}: prior {r["prior_metric"]}, '
        f'current balanced accuracy {fnum(r["current_balanced_accuracy"])} '
        f'(q={fnum(r["current_q"])})'
        for r in records
    )


def site_failure_text(records):
    parts = []
    for r in records:
        metric = "balanced accuracy" if r.get("outcome_type") == "binary" else "Q²"
        parts.append(
            f'{r.get("tumor_type")}–{r.get("endpoint")} ({metric} '
            f'{fnum(r.get("original_metric"))} to {fnum(r.get("site_grouped_metric"))})'
        )
    return "; ".join(parts)


def selected_prior_records(keys):
    selected = []
    for cancer, gene, study in keys:
        match = next((
            r for r in lit_accuracy
            if r["cancer"] == cancer and r["gene"] == gene and r["study"] == study
        ), None)
        if match:
            selected.append(match)
    return selected


previously_reported_not_supported = selected_prior_records([
    ("BRCA", "TP53", "Kather2020"),
    ("UCEC", "TP53", "Loeffler2022"),
    ("LIHC", "CTNNB1", "Kather2020"),
    ("PAAD", "KRAS", "Kather2020"),
])


doc = setup(Document(), "TITAN patient-level benchmark and model resource")
p = doc.add_paragraph(style="Title"); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run(MANUSCRIPT_TITLE)
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
authors = [
    ("Aamilah Ismail", "3,*"),
    ("Martin Ocharo", "1,2,*"),
    ("Moussa Kassim", "1,2"),
    ("Dalia Ahmed", "1"),
    ("Brendon Price", "5"),
    ("Dupe Ojo", "1"),
    ("Ekene Emmanuel Nweke", "4"),
    ("Silvano Piazza", "6,8"),
    ("Dinesh Gupta", "7"),
    ("Stefano Cacciatore", "1,2,†"),
]
for i, (name, markers) in enumerate(authors):
    if i:
        p.add_run(", ")
    p.add_run(name).bold = True
    marker_run = p.add_run(markers)
    marker_run.font.superscript = True
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("1 ").bold = True
p.add_run("Bioinformatics Unit, International Centre for Genetic Engineering and Biotechnology (ICGEB), Cape Town 7925, South Africa")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("2 ").bold = True
p.add_run("Department of Integrative Biomedical Sciences, Institute of Infectious Disease & Molecular Medicine (IDM), University of Cape Town, Cape Town 7925, South Africa")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("3 ").bold = True
p.add_run("Division of Engineering, New York University Abu Dhabi, Abu Dhabi, United Arab Emirates")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("4 ").bold = True
p.add_run("Department of Surgery, Faculty of Health Sciences, University of the Witwatersrand, Johannesburg, Gauteng, South Africa")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("5 ").bold = True
p.add_run("Division of Anatomical Pathology, University of Cape Town and National Health Laboratory Service, Observatory, Cape Town, South Africa")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("6 ").bold = True
p.add_run("Computational Biology Group, International Centre for Genetic Engineering and Biotechnology (ICGEB), Trieste, Italy")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("7 ").bold = True
p.add_run("Translational Bioinformatics Group, International Centre for Genetic Engineering and Biotechnology (ICGEB), Aruna Asaf Ali Marg, New Delhi 110067, India")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("8 ").bold = True
p.add_run("Bioinformatics Facility, Department of Cellular, Computational and Integrative Biology - CIBIO, University of Trento, Trento, Italy")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("* These authors contributed equally.").italic = True
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("† Corresponding author: Stefano Cacciatore (stefano.cacciatore@icgeb.org).").italic = True
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("Author emails: aamilahismail@gmail.com; moussa.kassim@icgeb.org; dalia.ahmed@icgeb.org; dupe.ojo@icgeb.org; stefano.cacciatore@icgeb.org")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("Research article — Molecular Pathology | Journal of Translational Medicine")

doc.add_heading("Abstract", level=1)
add_labelled(doc, "Background.", "Pan-cancer histology studies have already screened broad molecular endpoint spaces: Arslan and colleagues trained 12,093 models for 4,031 biomarkers across the same 32 TCGA cancers. We therefore evaluated TITAN as a reproducible patient-level benchmark and reusable model resource, rather than claiming a first pan-cancer screen or unprecedented mutation targets.")
add_labelled(doc, "Methods.", f"We mean-pooled {n_slides:,} primary diagnostic slide embeddings into {n_patients:,} patient vectors across {n_cancers} TCGA cancers; {n_multi:,} patients contributed multiple slides. We tested {len(continuous):,} continuous and {len(binary):,} binary cancer–endpoint pairs. PLS1 regression was used for continuous targets; binary targets used PLS latent scores with LDA. Patient-level nested 5×5 cross-validation selected 1–10 components. Effect-eligible models underwent a 999-permutation refinement with conservative sequential stopping, Benjamini–Hochberg control within cancer and endpoint family, and a stricter across-cancer family correction.")
add_labelled(doc, "Results.", f"Within-cancer screening identified {len(supported_c):,} continuous and {len(supported_b):,} binary higher- or moderate-effect candidates. Highlighted repeated-CV results included {abstract_metric_text}. The literature audit found prior statistical support for {len(prior_supported_mutations)}/{len(mutation_literature_audit)} screen-positive cancer–gene pairs. Under the multiplicity sensitivity, {global_abstract_text}; its attainable q-values in large families were limited by the 0.001 empirical-p resolution. Site grouping reduced {ival(site_combined.get('below_threshold_models'))}/{ival(site_combined.get('screen_positive_models'))} candidates ({fnum(site_combined.get('below_threshold_percent'), 1)}%) below the original effect threshold. In a selection-conditioned 24-model benchmark, median ridge-minus-PLS differences were 0.007 balanced accuracy and 0.014 Q², showing no uniform PLS advantage.")
add_labelled(doc, "Conclusions.", "This systematic patient-level benchmark defines internally derived TCGA estimates under one fixed pretrained TITAN representation and constructs compact research models for future locked evaluation. Its contribution is methodological and resource-oriented rather than mutation-target novelty. No independent performance evidence is presented, and clinical interpretation or application is not supported.")
add_labelled(doc, "Trial registration.", "Not applicable.")
doc.add_paragraph("Keywords: computational pathology; whole-slide imaging; foundation model; mutation; inflammation; microsatellite instability; gene fusion; aneuploidy; partial least squares; linear discriminant analysis")

doc.add_heading("Background", level=1)
doc.add_paragraph("Routine haematoxylin-and-eosin sections reflect phenotypic consequences of tumour genotype and the immune microenvironment. Coudray and colleagues established mutation prediction from lung histology [1]. Subsequent work predicted microsatellite instability, including externally validated colorectal models [2,3]; extended mutation and multi-omic screening across TCGA cancers [4,5,8,11,13]; inferred RNA expression [6,12]; identified tissue-source-site bias [7]; detected gene fusions [9,10]; estimated homologous-recombination deficiency [14]; and characterised tumour-microenvironment phenotypes [15]. Collectively, these studies establish biological plausibility while also showing that performance depends on endpoint, disease, cohort and validation design.")
doc.add_paragraph("Breadth alone is not the gap. Fu et al. analysed 17,355 slides across 28 cancers [4], Kather et al. applied one workflow to more than 5,000 patients across 14 cancers [5], Saldanha et al. externally tested mutation models across seven matched TCGA and CPTAC cancers [11], and Arslan et al. trained 12,093 models for 4,031 genomic, transcriptomic, proteomic and clinical biomarkers in 8,890 TCGA patients across the same 32 cancers [13]. The present study consequently does not claim the first pan-cancer molecular screen, a larger endpoint catalogue, or general mutation-target novelty.")
doc.add_paragraph("The narrower unresolved gap is a reproducible benchmark that applies one fixed pretrained representation to every target; deterministically aggregates slides before outcome matching; performs nested validation with the patient as the unit; preserves tested-negative and sample-size-ineligible results; reports target-level tissue-source-site sensitivity; models selected immune and genomic-context measurements continuously; and constructs compact fitted predictors with research-use provenance metadata. These design and resource features—not unprecedented endpoint classes—define the contribution of this study (Table 1).")
doc.add_paragraph("TITAN is a multimodal whole-slide foundation model pretrained on 335,645 slides with visual self-supervision and vision–language alignment [16]. The published Mass-340K pretraining corpus explicitly excluded TCGA and PANDA; TCGA was instead used for downstream evaluation of the pretrained model. The present work therefore has no reported TCGA pretraining overlap, but it is a secondary analysis of a cohort previously used to benchmark TITAN and is not independent external validation. We use its fixed 768-dimensional slide representation with PLS, a latent-variable method suited to correlated high-dimensional predictors [17,18].")
doc.add_paragraph("A practical feature of the fitted analysis is model portability. A PLS or PLS–LDA predictor can be distributed as preprocessing parameters, latent-variable weights, regression coefficients and LDA parameters. Prediction therefore does not require release of the patient-level training embeddings or outcomes. This supports external research testing while minimising distribution of patient-level data, but does not itself establish privacy, licensing compatibility or transportability.")
doc.add_paragraph("The primary question was cancer-specific: which individual mutations, inflammatory measurements, oncogenic pathways, MSI phenotypes, aneuploidy measures and fusions are predictable within each cancer? Molecular subtype association was not analysed. PLS–LDA was preferred for individual binary molecular endpoints. The methodological PLS1–PLS2 comparison for correlated inflammatory panels is reported in the Supplementary Material.")
add_landscape_section(doc)
doc.add_paragraph("Table 1. Comparison with major pan-cancer histology–molecular prediction studies. Panel A summarises cohort, endpoint and representation design; Panel B summarises validation, robustness, reporting and reusable predictor availability.", style="Caption")
doc.add_paragraph("Panel A. Cohort, endpoints, representation and patient aggregation.", style="Caption")
add_table(
    doc,
    ["Study", "Patients; cancers", "Slides", "Endpoint classes", "Representation; patient aggregation"],
    [(
        r["study"], f'{r["patients"]}; {r["cancer_types"]} cancers', r["slides"],
        r["endpoint_classes"], f'{r["representation"]}. {r["patient_aggregation"]}'
    ) for r in pan_cancer_comparison],
    [3.0, 4.0, 3.0, 7.5, 9.0],
)
doc.add_paragraph("Panel B. Validation, site sensitivity, negative-result reporting and predictor availability.", style="Caption")
add_table(
    doc,
    ["Study", "Validation design", "Site sensitivity", "External validation", "Negative/ineligible reporting", "Fitted predictors"],
    [(
        r["study"], r["validation_design"], r["site_sensitivity"],
        r["external_validation"], r["negative_and_ineligible_reporting"], r["fitted_predictors"]
    ) for r in pan_cancer_comparison],
    [3.0, 4.7, 3.8, 5.0, 5.5, 4.5],
)
doc.add_paragraph("NR, not reported as a single total in the main article. 'No fitted predictor library identified' means that code or outputs may be public, but the primary report did not describe a reusable target-specific fitted-model collection comparable with TITANPred.")
add_portrait_section(doc)

doc.add_heading("Methods", level=1)
doc.add_heading("Study design, slides and patient unit", level=2)
doc.add_paragraph(f"The published TITAN TCGA table contained {n_slides:,} eligible primary-tumour diagnostic slides (TCGA sample type 01 and –DX filename) from {n_patients:,} participants. The {n_multi:,} participants with multiple eligible slides contributed one patient vector obtained by feature-wise arithmetic mean before outcomes were joined. Patient—not slide—was the independent cross-validation unit. TITAN's TCGA-Slide-Reports.csv matched {n_exact_reports:,} selected slides exactly by filename; {n_unmatched_reports:,} slides lacked an exact report row. Report metadata were used only to audit identifiers, project/cancer provenance and resection-site annotations, and no report text entered a model. The two-character tissue-source-site code used for grouped validation was derived directly from the TCGA participant barcode. {n_missing_cancer:,} participants without a resolvable cancer label did not enter cancer-specific modelling. No participant had eligible slides from more than one primary sample barcode.")
doc.add_paragraph("All models were stratified by cancer type. No model learned pan-cancer differences, and no patient could occur in more than one validation fold. The intended use was discovery-stage prioritisation rather than diagnosis, treatment selection or replacement of molecular testing.")
doc.add_paragraph("All available eligible TCGA participants were used; no formal power calculation was performed. Minimum outcome-specific denominators were prespecified to support nested folds. Treatments were not modelled because the endpoints were contemporaneous molecular or immune measurements rather than prognosis or treatment response. Available demographic fields, subgroup sizes and endpoint-specific missingness did not provide a basis for representative subgroup performance or fairness evaluation; this is considered a limitation rather than evidence of equivalent performance across groups.")
doc.add_paragraph("Reporting was audited against TRIPOD+AI [28]. Participant characteristics were linked from the TCGA Clinical Data Resource [29] and summarized overall and by cancer. These descriptive fields were not supplied to prediction models, and no subgroup performance comparison was prespecified.")
add_figure(doc, "Figure1_patient_first_workflow.png", "Figure 1. Patient-first study design. Eligible diagnostic slides are mean-pooled before outcome matching; all model selection and evaluation occur at patient level within cancer type.")

doc.add_heading("Predictors and outcomes", level=2)
doc.add_paragraph("Predictors were the 768 fixed pretrained TITAN dimensions released for the TCGA slides [16]. The official gated artifact, TCGA_TITAN_features.pkl, was downloaded from https://huggingface.co/MahmoodLab/TITAN/blob/main/TCGA_TITAN_features.pkl after accepting the upstream terms and converted with the repository script to filename,titan_000,…,titan_767 CSV format; its source and converted-file SHA-256 hashes are retained in the provenance record. No slide pixels were reprocessed and TITAN weights were not fine-tuned in this study. Continuous outcomes comprised 39 immune/inflammatory measures and 11 genomic-context scores from Thorsson et al. [19], three aneuploidy burdens from Taylor et al. [20], log-transformed fusion burden from Gao et al. [21], and MANTIS/MSIsensor scores from Bonneville et al. and the cBioPortal TCGA PanCancer Atlas files [22,23]. Binary outcomes comprised qualifying protein-altering PASS mutations in tissue-specific consensus cancer genes from MC3 and Bailey et al. [24,25], ten oncogenic-pathway alteration indicators [26], genome doubling [20], any called fusion and eligible recurrent fusion pairs [21], and MSI-H definitions at MANTIS >0.4 and a strict >0.6 sensitivity threshold [22]. Protein-altering classes were missense, nonsense, nonstop, splice-site and translation-start mutations plus frameshift and in-frame insertions or deletions; their inclusion is recorded in a cancer-level variant-class audit. A mutation target denotes a qualifying alteration in a cancer gene; it does not assert that every allele is a functionally validated driver.")
doc.add_paragraph("The Thorsson Nonsilent Mutation Rate, Silent Mutation Rate, SNV Neoantigens, Indel Neoantigens and Number of Segments variables, and the Gao fusion burden, were analysed as log(1+x); all other continuous endpoints retained their source scale. Reported RMSE values therefore use these analysed units.")
doc.add_paragraph(f"Molecular missingness was retained rather than converted to a negative label, and no outcome imputation was performed. Mutation status was defined only among {n_mc3_profiled:,} embedding patients matched to an MC3 primary-tumour profile; {n_mc3_missing:,} embedding patients without such a profile were excluded from mutation denominators. Within this profiled set, wild type meant no qualifying PASS protein-altering variant in the specified gene. Fusion-negative status was assigned only within the Gao study sample list. Multiple primary aliquots, if present, were collapsed at patient level by any alteration for binary mutation/pathway/fusion endpoints and by the prespecified mean or any-positive rule for continuous or binary instability endpoints. The source-level coverage table records covered patients, missing patients, aliquot multiplicity and aggregation for every cancer and source; no source contained multiple primary aliquots among matched embedding patients in this release.")
doc.add_paragraph("Continuous pairs required at least 50 non-missing patients. Binary pairs required at least 20 positive and 20 negative patients. Eligibility was decided before modelling and every eligible test remained in its endpoint-family multiplicity denominator.")

doc.add_heading("PLS1 regression and PLS–LDA classification", level=2)
doc.add_paragraph("For each cancer–endpoint pair, five outer folds estimated performance and five inner folds selected 1–10 PLS components. Scaling and component selection were learned from training patients only. All primary, permutation, repeated, sensitivity, PLS1–PLS2 and final-model fits used CPU rSVD with 10 oversampling vectors, two power iterations and explicit seeds. Continuous performance was out-of-fold Q², with RMSE and Spearman correlation secondary. Binary models supplied PLS latent scores to ridge-stabilised LDA; balanced accuracy was primary and AUROC from continuous LDA scores was secondary in repeated validation.")
doc.add_paragraph("Q² was 1−Σ(y−ŷ)²/Σ(y−ȳ)² over outer-fold predictions, and RMSE was the square root of the mean squared prediction error. For binary outcomes, class 1 denoted altered or positive and class 0 denoted wild type or negative within the outcome-specific covered denominator. Sensitivity was the class-1 true-positive rate, specificity the class-0 true-negative rate, and balanced accuracy their arithmetic mean. AUROC used the continuous class-1-minus-class-0 LDA discriminant score; Spearman correlation used observed and held-out continuous predictions.")
doc.add_paragraph("As a secondary algorithmic benchmark, the 24 manuscript-highlighted models were refitted on the same five repeated outer partitions using ridge-penalised Gaussian regression for continuous endpoints and ridge logistic regression for binary endpoints. Ridge hyperparameters were selected inside each outer training set; binary operating thresholds maximised balanced accuracy using inner out-of-fold probabilities. The primary paired differences were ridge-minus-PLS Q² and balanced accuracy, with AUROC or Spearman correlation retained as secondary metrics. We report the magnitude, interquartile range and 95% paired-repeat interval rather than declaring a winner from counts alone. Because models were selected for this benchmark after the PLS screen, it is a conditional sensitivity analysis and cannot establish screen-wide algorithmic superiority. Ridge was chosen as a simple linear baseline whose fitted coefficients can be exported without retaining training embeddings; nonlinear kernel predictors that require training observations or landmarks at inference did not satisfy that portability constraint.")
doc.add_paragraph("No class under-sampling, over-sampling or synthetic augmentation was used. LDA used the observed training-fold class priors and returned a class plus an uncalibrated discriminant score, not a probability or clinical-risk threshold. Outcome tables were constructed independently of TITAN feature processing and joined only after patient-level aggregation.")
doc.add_paragraph("Nested performance was first checkpointed for the complete screen. Only models with Q²≥0.20 or chance-corrected balanced accuracy≥0.20 entered permutation testing. A 99-permutation checkpoint was followed by refinement toward 999 patient-label permutations. During final refinement, evaluation stopped conservatively after 49 exceedances because raw p<0.05 was then impossible even if every remaining null statistic were less extreme; stopped endpoints were assigned p=1. Early-stopped checkpoint jobs resumed from the exact number attempted, so no permutation indices were skipped. Regression extremeness used lower RMSE, whereas classification used higher balanced accuracy. Completed finite p values were (b+1)/(B+1), giving minimum resolution 0.001. Because each disease defines a separate prediction and intended-use population, Benjamini–Hochberg FDR was controlled separately for continuous and binary screens within cancer and prespecified endpoint family [27]; a q-value across cancers within the same outcome type and family was retained as a stricter multiplicity sensitivity. Effect denotes Q² for continuous outcomes and 2×balanced accuracy−1 for binary outcomes. Screen-positive candidates were described as higher effect (primary q<0.05 and effect≥0.40) or moderate effect (primary q<0.05 and effect 0.20–0.39). Screen-negative tested pairs and pairs ineligible by sample-size rules were reported separately. These categories prioritise candidates for further testing and are not clinical grades.")

doc.add_heading("Robustness and saved models", level=2)
doc.add_paragraph("Screen-positive models were repeated under five independently seeded nested-CV partitions; each repeat seed governed both fold construction and rSVD. Sensitivity, specificity, balanced accuracy and AUROC were calculated within each repeat for binary endpoints; Q², RMSE and Spearman correlation were calculated within each repeat for continuous endpoints. Reported repeated-CV point estimates were the arithmetic mean of the five repeat-specific metrics, so LDA scores from independently fitted repeats were never pooled onto an assumed common scale. For highlighted models, 1,000 patient-cluster bootstrap resamples retained all five held-out predictions for each sampled patient, recalculated metrics within repeat and then averaged them; percentile 2.5th and 97.5th quantiles formed the 95% intervals. Site-grouped validation assigned all patients sharing a two-character TCGA tissue-source-site code to the same outer fold, preventing a site from appearing in both training and test partitions for that fold. A sensitivity analysis replaced each mean-pooled vector with the lexicographically first eligible diagnostic slide while preserving patients and seeds. Full-data research models were tuned by ten-fold CV and saved with feature order and checksum, training ranges, aggregation rule, endpoint transformation and output units, class coding and priors, decision rule, calibration status, class counts, exact software version and commit, computation backend, rSVD controls, external-validation status and intended-use metadata.")
doc.add_paragraph("TITANPred retains the binary LDA score but does not convert it to a probability. In the research-software demonstration, its position is labelled 'TCGA out-of-fold score rank (not probability)' rather than percentile or risk, and is displayed beside total training n, positive and negative counts, prevalence, repeated-CV balanced accuracy and AUROC. Models with fewer than 50 patients in either class receive an explicit limited-class-size warning; this reporting flag does not change the prespecified 20-per-class eligibility rule. Probability calibration was not added post hoc because it would require an independently evaluated or fully nested calibration procedure, which is not available in this TCGA benchmark.")
doc.add_paragraph("The fitted PLS and PLS–LDA objects contain the learned transformations and coefficients needed for research inference but no patient-level training rows. The access-controlled inference interface validates the 768-feature order and applies the prespecified patient-level slide aggregation. The secondary PLS1–PLS2 inflammatory comparison, including matched folds and cancer-bootstrap intervals, is described in the Supplementary Methods.")

doc.add_heading("Software, transparency and validation status", level=2)
doc.add_paragraph("Analyses used R 4.6.0 and fastPLS 0.99.20 (Git commit dcf45cc). MC3 objects were loaded with TCGAmutations 0.4.0 from the GitHub source pinned in the software manifest. Version-controlled code, source manifests, target catalogues, out-of-fold prediction summaries, figures and the model registry are organized in the public companion analysis repository [30]. A separate access-controlled GPL-3 R package contains the fitted models, their SHA-256 registry, reference distributions, inference interface and research-software output template [32]. That repository is private and the manuscript does not claim public availability of the fitted artifacts. The artifacts contain learned parameters and training-range summaries but no patient-level training rows. No independent cohort with compatible TITAN features and the required labels was included; every performance estimate is an internally derived TCGA estimate.")
doc.add_heading("Prospectively locked protocol for future independent evaluation", level=2)
doc.add_paragraph("After the internal TCGA screen, but before accessing any external features, outcomes or predictions, we fixed a three-model UCEC subset for future independent evaluation: TP53 mutation, genome doubling and continuous aneuploidy score. The exact fitted-object SHA-256 hashes are c39ba2caeefc148e67412647f3e1835dbcd719088a4d379b53068482ebb2ede0, 8f9fd73578189bab5d5c88bb8005415a07b93a662f2b0adb893f0b04e1cc3604 and 0c520d8a9d57dd5af109416c5b82ffb0f0862e3505cd9888965fdeee4aa60f3b, respectively. Their internal performance is selection-conditioned; locking them now does not convert TCGA estimates into external evidence.")
doc.add_paragraph("A future evaluation must extract every eligible primary-tumour diagnostic slide with the documented CONCH v1.5–TITAN pipeline, apply the same deterministic patient mean pooling, preserve the 768-feature order and use the hashed artifacts without refitting, recalibration, class-prior changes or threshold adjustment. Outcomes must be constructed independently of image predictions using definitions compatible with the TCGA targets; an irreproducible endpoint must be reported as non-evaluable rather than replaced with an externally optimised surrogate. Binary primary performance is balanced accuracy, with AUROC, sensitivity and specificity secondary; continuous primary performance is Q², with RMSE, Spearman correlation, calibration intercept and calibration slope secondary. Patient/slide flow, molecular missingness, exclusions, denominators, uncertainty and all three outcomes—including failures—must be reported. The executable specification and machine-readable lock file are provided in the companion repository.")
doc.add_paragraph("OpenAI Codex was used for analysis-code refactoring, document generation and language editing. All statistical choices, source-data mappings, numerical outputs and manuscript interpretations were reviewed by the human authors, who retain responsibility for the work.")
doc.add_paragraph("Supplementary methods, Tables S1–S12, Figures S1–S2 and the machine-readable-file inventory are provided in Additional file 1. The two illustrative single-sample TITANPred reports are supplied separately as Additional files 2 and 3.")

doc.add_heading("Results", level=1)
doc.add_heading("Cohort and analysis coverage", level=2)
doc.add_paragraph(f"The embedding cohort contained {n_patients:,} patients represented by {n_slides:,} slides; {n_multi:,} patients ({100*n_multi/n_patients:.1f}%) had more than one eligible diagnostic slide. The maximum was 30 slides for one patient, and no patient contributed slides from multiple primary sample barcodes. Exact slide-report coverage was {n_exact_reports:,}/{n_slides:,} ({100*n_exact_reports/n_slides:.1f}%). Cancer labels were available for {n_patients-n_missing_cancer:,} patients across {n_cancers} cancers. The benchmark evaluated {len(continuous):,} continuous and {len(binary):,} binary cancer–endpoint pairs (Table 2). Of {len(mutation_eligibility):,} prespecified cancer–gene mutation pairs with a profiled denominator, {n_mutation_eligible:,} met the 20-positive/20-negative rule and {n_mutation_ineligible:,} were reported as ineligible rather than tested-negative. Molecular coverage varied by source and cancer; missing cases were excluded outcome by outcome.")
if participant_overall:
    known_gender = ival(participant_overall.get("female")) + ival(participant_overall.get("male"))
    doc.add_paragraph(
        f'The TCGA Clinical Data Resource [29] matched {ival(participant_overall.get("cdr_matched")):,}/{n_patients:,} participants. '
        f'Age was available for {ival(participant_overall.get("age_available")):,} participants (median {fnum(participant_overall.get("age_median"), 1)} years, IQR {fnum(participant_overall.get("age_q1"), 1)}–{fnum(participant_overall.get("age_q3"), 1)}); '
        f'{ival(participant_overall.get("female")):,}/{known_gender:,} with recorded gender were female. '
        f'Race was recorded for {ival(participant_overall.get("race_available")):,} and broad stage I–IV for {ival(participant_overall.get("stage_available")):,}. '
        "These fields describe cohort composition only; subgroup predictive performance was not evaluated."
    )
doc.add_paragraph("Table 2. Eligible cancer–endpoint models and within-cancer screening categories.", style="Caption")
add_table(doc, ["Family", "Type", "Tests", "Cancers", "Higher effect", "Moderate effect", "Screen-negative"], family_table,
          [4.8, 2.0, 1.5, 1.5, 1.5, 1.5, 1.5])

doc.add_heading("Continuous immune, genomic-context and instability phenotypes", level=2)
doc.add_paragraph(f"Among continuous targets, {len([r for r in supported_c if r['tier']=='A'])} were within-cancer screen-positive with higher effects and {len([r for r in supported_c if r['tier']=='B'])} with moderate effects. The strongest effects were {examples(top_c, 'q2', 10)}. These results were cancer specific: the same endpoint could be strongly predictable in one tumour type and screen-negative in another.")
doc.add_paragraph(f"Of {len(supported_c)} within-cancer screen-positive continuous pairs, {len(global_supported_c)} met q<0.05 under the stricter across-cancer family sensitivity after the 999-permutation refinement. " + ("Continuous findings should therefore be interpreted as cancer-specific candidates rather than globally FDR-supported pan-cancer discoveries. Because the minimum completed-test p-value was 0.001, the global sensitivity was resolution-limited for large endpoint families; failure to pass it is not evidence of absence of biological signal." if not global_supported_c else "Pairs passing this sensitivity are identified explicitly in the figure and machine-readable table; the remainder are cancer-specific candidates. The 0.001 minimum completed-test p-value should be considered when interpreting large global families."))
add_figure(doc, "Figure2_continuous_atlas.png", "Figure 2. Strongest within-cancer screen-positive continuous cancer–endpoint results. Q² is calculated from genuine patient-level outer-fold predictions; all tests remain available in the machine-readable benchmark results.")

doc.add_heading("Binary molecular phenotypes", level=2)
doc.add_paragraph(f"The binary screen yielded {len([r for r in supported_b if r['tier']=='A'])} within-cancer higher-effect and {len([r for r in supported_b if r['tier']=='B'])} moderate-effect candidates. Leading results were {examples(top_b, 'balanced_accuracy', 12, include_family=True)}. The complete table distinguishes tested-negative pairs from outcomes that failed prevalence or sample-size eligibility.")
doc.add_paragraph(f"Of {len(supported_b)} within-cancer screen-positive binary pairs, {len(global_supported_b)} also met the stricter across-cancer family q<0.05, including {len(global_mutation_b)} cancer–gene mutation pairs. " + ("Mutation results are consequently cancer-specific discovery candidates, even where their within-cancer discrimination was strong. The 0.001 permutation resolution also limits the attainable across-cancer q-value for a mutation family spanning many cancer–gene tests." if not global_mutation_b else "Mutation pairs passing this stricter sensitivity are distinguished from those supported only within cancer; the 0.001 permutation resolution remains relevant for the full mutation family."))
add_figure(doc, "Figure3_binary_atlas.png", "Figure 3. Strongest within-cancer screen-positive binary molecular predictions using PLS latent scores and LDA. Point size represents the number of positive patients; colour indicates endpoint family and symbols report across-cancer correction status.")
add_figure(doc, "Figure4_prediction_examples.png", "Figure 4. Examples comparing observed outcomes with held-out predictions. Panel A shows the strongest primary patient-level nested-CV continuous result (TGCT TGF-beta Response); each point is one patient's observed value and genuine held-out prediction. Panel B shows the binary model with the largest mean repeated-CV balanced accuracy. Because independently fitted LDA scores need not share a raw scale, held-out scores are standardized within repeat before patient-level averaging for display; repeat-specific AUROCs use untransformed scores. These deliberately strong examples are illustrative, selection-conditioned internal TCGA results rather than external validation or calibration.")
if highlighted:
    h_cont = [r for r in highlighted if r.get("outcome_type") == "continuous"][:4]
    h_bin = [r for r in highlighted if r.get("outcome_type") == "binary"][:4]
    doc.add_paragraph("Table 3. Highlighted repeated nested-cross-validation performance with 95% patient-cluster bootstrap intervals.", style="Caption")
    performance_rows = []
    for r in h_cont:
        performance_rows.append((r["tumor_type"] + "–" + r["endpoint"], "continuous",
                                 f'{fnum(r.get("q2"))} ({fnum(r.get("q2_ci_low"))}–{fnum(r.get("q2_ci_high"))})',
                                 f'{fnum(r.get("rmse"))} ({fnum(r.get("rmse_ci_low"))}–{fnum(r.get("rmse_ci_high"))})',
                                 f'{fnum(r.get("spearman"))} ({fnum(r.get("spearman_ci_low"))}–{fnum(r.get("spearman_ci_high"))})'))
    for r in h_bin:
        performance_rows.append((r["tumor_type"] + "–" + r["endpoint"], "binary",
                                 f'Se {fnum(r.get("sensitivity"))} ({fnum(r.get("sensitivity_ci_low"))}–{fnum(r.get("sensitivity_ci_high"))}); '
                                 f'Sp {fnum(r.get("specificity"))} ({fnum(r.get("specificity_ci_low"))}–{fnum(r.get("specificity_ci_high"))})',
                                 f'BA {fnum(r.get("balanced_accuracy"))} ({fnum(r.get("balanced_accuracy_ci_low"))}–{fnum(r.get("balanced_accuracy_ci_high"))})',
                                 f'AUROC {fnum(r.get("auc"))} ({fnum(r.get("auc_ci_low"))}–{fnum(r.get("auc_ci_high"))})'))
    add_table(doc, ["Cancer–endpoint", "Type", "Q² or Se/Sp (95% CI)", "RMSE or BA (95% CI)", "Spearman or AUROC (95% CI)"], performance_rows)
add_figure(doc, "Figure5_supported_counts.png", "Figure 5. Breadth and family of within-cancer screen-positive prediction targets. Absence of an eligible target is distinct from a tested screen-negative result.")

doc.add_heading("Exportable linear baseline comparison", level=2)
binary_baseline_summary = next((r for r in ridge_summary if r.get("outcome_type") == "binary"), {})
continuous_baseline_summary = next((r for r in ridge_summary if r.get("outcome_type") == "continuous"), {})
doc.add_paragraph(
    f"Among the 12 highlighted binary models, the median ridge-minus-PLS balanced-accuracy difference was "
    f"{fnum(binary_baseline_summary.get('median_delta_ridge_minus_pls'))} "
    f"(IQR {fnum(binary_baseline_summary.get('q1_delta'))} to {fnum(binary_baseline_summary.get('q3_delta'))}); "
    f"ridge had a paired-repeat interval above zero for {sum(r.get('outcome_type') == 'binary' for r in ridge_better)} models, "
    f"PLS for {sum(r.get('outcome_type') == 'binary' for r in pls_better)}, and "
    f"{sum(r.get('outcome_type') == 'binary' for r in baseline_uncertain)} differences were uncertain. "
    f"For the 12 continuous models, the median ridge-minus-PLS Q² difference was "
    f"{fnum(continuous_baseline_summary.get('median_delta_ridge_minus_pls'))} "
    f"(IQR {fnum(continuous_baseline_summary.get('q1_delta'))} to {fnum(continuous_baseline_summary.get('q3_delta'))}); "
    f"ridge was favoured for {sum(r.get('outcome_type') == 'continuous' for r in ridge_better)}, "
    f"PLS for {sum(r.get('outcome_type') == 'continuous' for r in pls_better)}, and "
    f"{sum(r.get('outcome_type') == 'continuous' for r in baseline_uncertain)} were uncertain. "
    "Thus PLS was competitive but not uniformly superior to a simpler exportable linear model. Because the benchmark was restricted to PLS-highlighted results, the prespecified PLS workflow was retained and the comparison is reported as selection-conditioned sensitivity evidence rather than a basis for post-screen method switching."
)

doc.add_heading("Site and multiple-slide sensitivity", level=2)
doc.add_paragraph(
    f"Site-grouped validation was feasible for {sum(r.get('feasible')=='TRUE' for r in site_c)+sum(r.get('feasible')=='TRUE' for r in site_b)} screen-positive models. "
    f"Although the median grouped-minus-random performance change was only {fnum(median(site_deltas))}, "
    f"{ival(site_combined.get('below_threshold_models'))}/{ival(site_combined.get('screen_positive_models'))} "
    f"models ({fnum(site_combined.get('below_threshold_percent'), 1)}%) fell below the original effect threshold: "
    f"58/219 continuous models and 25/104 binary models. Prominent attenuations were "
    f"{site_failure_text(site_named_failures)}. The site-grouped folds contain fewer and less evenly distributed "
    "training patients, so the decline cannot be attributed solely to site artefact; nevertheless, the near-chance "
    "colorectal APC results are not adequately summarised by the median and are treated as site-sensitive. "
    f"The first-slide-minus-mean-pool median change across screen-positive models was {fnum(median(pool_deltas))}."
)
add_figure(doc, "Figure6_site_grouped_sensitivity.png", "Figure 6. Random-fold versus tissue-source-site-grouped internal validation. Values below the diagonal indicate attenuation when submitting tissue-source sites are separated.")

doc.add_heading("External-validation readiness audit", level=2)
doc.add_paragraph("No non-TCGA patient entered model evaluation, and no external performance result is reported. The official TITAN release provided the precomputed TCGA representation used here, but the audit did not identify a compatible non-TCGA TITAN embedding set carrying the required outcomes. CPTAC-UCEC is a plausible future cohort: its official TCIA collection reports 250 subjects, 887 pathology whole-slide images (approximately 154 GB) and links to genomic, proteomic and clinical resources [36]. Those slides were not downloaded or processed in this study, and the availability of linked data does not by itself guarantee exact reconstruction of each endpoint.")
doc.add_paragraph("Table 4 records the three fitted UCEC artifacts locked for any future untouched evaluation. The displayed performance values are internally derived TCGA estimates included only to document why the targets were selected; they are not external benchmarks. All three must be reported under the protocol, including chance-level performance, extraction failure or endpoint non-evaluability.")
add_table(
    doc,
    ["Locked target", "Artifact SHA-256 (prefix)", "Internal repeated-CV estimate", "Site-grouped estimate", "Future primary metric", "Status"],
    [(
        f'{r["cancer_type"]}–{r["endpoint"]}', r["model_sha256"][:12],
        r["internal_repeated_cv_primary"], r["site_grouped_metric"],
        r["locked_external_primary_metric"], r["external_validation_status"]
    ) for r in external_locked_targets],
    [2.6, 2.8, 3.4, 3.2, 2.6, 2.0],
)
doc.add_paragraph("Table 4. Prospectively locked subset for future independent evaluation. Model selection occurred after the TCGA screen but before any external feature, outcome or prediction was inspected. Full hashes, secondary metrics, endpoint-compatibility rules and mandatory failure reporting are provided in Supplementary Table S6c and the machine-readable lock file.", style="Caption")

doc.add_heading("Research-software demonstration and COAD illustration", level=2)
doc.add_paragraph(
    f"The access-controlled TITANPred R package contains {len(supported_c) + len(supported_b):,} fitted models "
    f"({len(supported_c):,} continuous and {len(supported_b):,} binary) across "
    f"{len({r['tumor_type'] for r in supported_c + supported_b})} cancers [32]. An authorised research user supplies "
    "a cancer vector and correctly named 768-dimensional TITAN features; the interface applies "
    "every bundled model available for that cancer. Repeated patient identifiers are mean-pooled "
    "before inference. Continuous outputs retain source endpoint units and are positioned against "
    "repeated out-of-fold reference distributions; binary outputs comprise the fitted PLS-LDA class "
    "and uncalibrated LDA score. The binary display labels its TCGA out-of-fold score rank explicitly "
    "as a rank rather than a probability and places training positive/negative counts, prevalence, "
    "repeated-CV performance and any limited-class-size warning beside the call. A single-sample research-software output renders all available continuous endpoints "
    "as a radar, with the exact reference percentile and original prediction printed at every corner, "
    "and displays binary calls with provenance and out-of-distribution diagnostics. The demonstration ends "
    "with definitions of every displayed endpoint and citations for the data source used to construct "
    "each TCGA model target."
)
doc.add_paragraph(
    f"COAD was chosen for a research-software demonstration because colorectal cancer, of which colon "
    f"adenocarcinoma is a major component, accounted for 1,926,425 new cases worldwide in 2022 "
    f"[31], and COAD contributed {len(coad_supported_c) + len(coad_supported_b)} supported models "
    f"({len(coad_supported_c)} continuous and {len(coad_supported_b)} binary). APC, TP53, KRAS "
    "and BRAF prediction from colorectal histology had already been evaluated in pooled colorectal "
    "and/or exact-COAD studies; these models are therefore replications or extensions under a different "
    "representation and validation framework, not bibliographically novel mutation targets. For visualization, "
    "we first restricted candidates to cases with a non-empty slide report that described a sigmoid-colon, "
    "moderately differentiated, pT3 adenocarcinoma with clear margins, and then required that no case had "
    "more than two of ten continuous predictions outside the first to 99th percentile. Among pairs sharing "
    "recorded sex and site, TCGA-AA-A01F and TCGA-AA-3972 had the largest Euclidean separation across the "
    "complete continuous prediction-percentile profile. This produced clinically comparable examples with "
    "predominantly intermediate rather than saturated values. Example A had higher MSI, mutation-rate and "
    "TIL predictions and lower aneuploidy predictions, whereas example B showed the converse pattern "
    "(Figure 7). The selection is a research-software demonstration of internally derived TCGA estimates, not a validation analysis or an "
    "estimate of clinical prevalence."
)
doc.add_paragraph(
    "The accompanying pathology text is paraphrased from TCGA-Slide-Reports.csv rather than reproduced "
    "verbatim. For TCGA-AA-A01F, the report describes an ulcerated grade-2 sigmoid adenocarcinoma extending "
    "through the muscular wall into pericolic fat (pT3), with uninvolved resection ends, lymphatic invasion "
    "and two involved nodes among 30 examined (pN1). For TCGA-AA-3972, it describes an ulcerated grade-2 "
    "sigmoid colorectal adenocarcinoma extending through the bowel wall into mesocolic fat (pT3), with "
    "uninvolved proximal and distal margins; a nodal category was not stated in the supplied slide summary."
)
doc.add_paragraph(
    "Public NCI Genomic Data Commons case records provide treatment context [33]. TCGA-AA-A01F received "
    "fluorouracil, leucovorin and oxaliplatin, for which the recorded treatment outcome was complete response. "
    "TCGA-AA-3972 received capecitabine plus oxaliplatin and, later, fluorouracil, leucovorin, oxaliplatin and "
    "bevacizumab; progressive disease was recorded for both treatment records, with recurrence documented "
    "later in follow-up. These fields are descriptive public metadata and were not predictors, training "
    "targets or validation outcomes. The examples therefore do not evaluate response prediction or treatment effect."
)
add_figure(
    doc,
    "Figure7_COAD_TITANPred_examples.png",
    "Figure 7. TITANPred research-software demonstration in two clinically comparable COAD cases. Panels A and B show all ten internally derived TCGA continuous estimates for TCGA-AA-A01F and TCGA-AA-3972, respectively. Silent mutation rate and SNV neoantigens flank nonsilent mutation rate in the semantic axis order. Every radar corner reports the exact percentile relative to corrected repeated out-of-fold TCGA predictions and the original model estimate in the analysed endpoint units; the percentiles are not clinical reference ranges. Panel C shows binary PLS-LDA calls and explicitly labelled TCGA out-of-fold LDA-score ranks; filled points denote positive calls, and ranks are not probabilities. Training n and class counts accompany each binary endpoint. The cases share sex, sigmoid site, grade, pT3 category and clear margins and were selected after limiting saturated continuous profiles. They are full-cohort research-software examples and do not provide external validation.",
    width=6.7,
)

doc.add_heading("Discussion", level=1)
doc.add_paragraph(f"This study is best interpreted as a systematic patient-level benchmark and reusable fitted-model resource, not as the first pan-cancer molecular-prediction study or a catalogue of unprecedented mutation targets. It answers a target-by-target, cancer-specific question using one fixed pretrained TITAN representation. Selected immune programmes, mutations and higher-level genomic phenotypes were predictable, but most eligible pairs did not satisfy both multiplicity and effect thresholds. That heterogeneity—and transparent negative and ineligible reporting—is the primary empirical result. Under the stricter across-cancer family correction, {len(global_supported_c)} continuous and {len(global_mutation_b)} mutation pairs passed; the remaining within-cancer candidates should not be interpreted as pan-cancer biomarkers. Conversely, global non-passage cannot be interpreted as evidence of no signal because the 0.001 empirical-p resolution restricts attainable q-values in large families.")
doc.add_paragraph("The closest breadth comparator is Arslan et al., who already trained 12,093 target-specific models for 4,031 multi-omic biomarkers in 8,890 TCGA patients across the same 32 cancers [13]. The present study is smaller in endpoint breadth and lacks external validation. Its differentiating elements are instead the fixed pretrained representation, deterministic pre-outcome patient aggregation, nested patient-level validation, complete tested-negative and ineligible outputs, target-level site-grouped sensitivity, continuous modelling of selected immune and genomic-context measures, and distribution of compact fitted linear predictors. Table 1 makes these distinctions explicit and prevents breadth or endpoint novelty from being inferred from the study framing.")
doc.add_paragraph("The relevant literature spans substantially different validation settings and metrics. For MSI, Kather et al. reported external AUROCs of 0.84 (95% CI 0.72–0.92) in DACHS colorectal cancer and 0.69 (0.52–0.82) in an external gastric cohort, whereas Echle et al. reported an external dMMR AUROC of 0.96 in a 771-case cohort [2,3]. For fusion prediction, Dadhania et al. reported ERG AUROCs of 0.82–0.85, and Mayer et al. reported 100% sensitivity with 100% and 98.6% specificity for ALK and ROS1, respectively, in a small external set [9,10]. Saldanha et al. externally evaluated mutation models in CPTAC, Bergstrom et al. reported external breast HRD AUROC 0.76 (0.71–0.82), and HistoTME reported mean external cell-composition correlation 0.50 and immunotherapy-response AUROC 0.75 (0.61–0.88) [11,14,15]. These externally tested results set a stronger validation standard than the internal TCGA estimates presented here; metric, endpoint and cohort differences preclude claims of direct superiority.")
doc.add_paragraph(
    f"The expanded primary-study audit substantially changes the novelty interpretation. "
    f"{len(prior_supported_mutations)}/{len(mutation_literature_audit)} screen-positive cancer–gene pairs "
    "had already received statistical support in reviewed histology-prediction studies, including pooled "
    "colorectal evidence mapped to both COAD and READ where appropriate. Examples include LGG–CIC "
    f"(prior mean AUROC 0.836, current balanced accuracy {fnum(next(r for r in mutation_literature_audit if r['cancer']=='LGG' and r['gene']=='CIC')['current_balanced_accuracy'])}), "
    "LGG–ATRX (prior mean AUROC 0.816), THCA–NRAS (0.809), LIHC–BAP1 (0.825), "
    "PAAD–TP53 (0.672) and KIRC–VHL (0.631) [13]. Prior studies generally reported AUROC, whereas "
    "the present primary metric is balanced accuracy; these values are contextual and are not estimates "
    "of improvement or inferiority."
)
doc.add_paragraph(
    f"Two current screen-positive pairs had been evaluated but were not statistically supported in the "
    f"reviewed 2024 study: BLCA–PIK3CA (prior mean AUROC 0.588, corrected p=0.058; current balanced "
    f"accuracy {fnum(next(r for r in prior_evaluated_not_supported if r['cancer']=='BLCA')['current_balanced_accuracy'])}) "
    f"and SKCM–BRAF (prior mean AUROC 0.579, corrected p=0.286; current balanced accuracy "
    f"{fnum(next(r for r in prior_evaluated_not_supported if r['cancer']=='SKCM')['current_balanced_accuracy'])}). "
    "Only THYM–GTF2I was not identified in the reviewed predictive-model literature; a strong direct "
    "GTF2I–thymoma morphology association is already established, so this result is presented as a "
    "prediction candidate requiring independent validation rather than a claim of biological novelty. "
    "The OV–TP53 entry is supported by a 2025 preprint reporting AUROC 0.82±0.02 and is labelled as "
    "preliminary evidence rather than peer-reviewed external validation [34]. The GTF2I morphology "
    "association itself was reported by Wells et al. [35]. Supplementary Table S10a and the "
    "machine-readable audit give the evidence scope, prior metric, source "
    "and note for every screen-positive pair."
)
doc.add_paragraph(
    "External results also caution against equating internal discrimination with transportability. For PAAD–TP53, "
    "the current TCGA balanced accuracy was 0.619 and Arslan et al. reported mean internal AUROC 0.672, "
    "whereas Saldanha et al. reported internal AUROC 0.554 and external CPTAC AUROC 0.443±0.064 [11,13]. "
    "Differences can arise from cohort composition, slide preparation, mutation definition, model class and "
    "validation design. The present result therefore supports further locked external testing, not clinical application."
)
doc.add_paragraph("The immune measurements, oncogenic pathways, MSI, aneuploidy and fusion endpoints extend the analysis beyond the exact cancer–gene mutation pairs used for the literature crosswalk. They are systematically benchmarked here with the same TITAN–PLS design, but the manuscript does not claim that histological prediction of those broad endpoint classes is unprecedented. Their contribution is the unified patient-level, cancer-specific evaluation and directly reusable linear modelling framework.")
doc.add_paragraph(f"For continuous outcomes, prior work predicted RNA expression [6], tumour composition [4], continuous HRD and microenvironment measures [12], and externally evaluated tumour-microenvironment composition in non-small cell lung cancer [15]. The present study instead screens the prespecified Thorsson immune panel, genomic-context scores, MSI scores, fusion burden and aneuploidy burdens across eligible TCGA cancers using the same patient-level validation design. Only {len(global_supported_c)} continuous pairs passed the stricter across-cancer correction; the others should be treated as endpoint- and cancer-specific nominations, not as replications of the external HistoTME results or as evidence of general immune profiling.")
doc.add_paragraph("The contribution of TITAN plus PLS is a uniform, auditable screen over many prespecified outcomes using one fixed pretrained representation, with one-at-a-time PLS–LDA retained for the prespecified individual binary endpoints and PLS2 examined secondarily for correlated inflammatory panels.")
doc.add_paragraph("The ridge benchmark prevents interpreting that design choice as proof of PLS superiority. Median ridge-minus-PLS differences were small (0.007 balanced accuracy for binary and 0.014 Q² for continuous models), although paired intervals favoured ridge for two binary and seven continuous highlighted endpoints and favoured PLS for one binary and two continuous endpoints. The remaining 12 comparisons were uncertain. Both approaches yield compact exportable parameters, so portability is not unique to PLS. PLS remains the prespecified primary method because the benchmark was performed only on PLS-highlighted models and switching methods after that selection would add another optimistic selection layer. Future external validation can compare locked PLS and ridge candidates prospectively.")
doc.add_paragraph(f"Site grouping revealed heterogeneity that the median attenuation concealed: {ival(site_combined.get('below_threshold_models'))}/{ival(site_combined.get('screen_positive_models'))} screen-positive models ({fnum(site_combined.get('below_threshold_percent'), 1)}%) fell below their original effect threshold. READ–APC and COAD–APC declined from balanced accuracies 0.862 and 0.793 to 0.495 and 0.543, respectively. Smaller and less balanced training folds contribute to grouped-validation loss, but performance close to chance requires these models to be labelled site-sensitive rather than robust biological signals. This reinforces the need for multi-institutional external validation and for publishing target-level, not only median, sensitivity results.")
doc.add_paragraph("A further practical feature is data-minimising model portability. Preprocessing values, latent weights and coefficients are sufficient for continuous prediction, with compact LDA parameters added for binary classification. The access-controlled TITANPred package applies cancer-matched models to correctly ordered TITAN features without requiring the original patient embeddings or outcomes [32]. Its current private status is stated explicitly; the manuscript makes no public-artifact availability claim. This design reduces the patient-level data that would need to be exchanged in authorised research, although it does not itself confer privacy, satisfy local governance requirements or establish transportability. The matched COAD cases demonstrate software output for internally derived TCGA estimates. Because both examples were chosen within TCGA and were evaluated by full-cohort fits, neither their molecular contrast nor their recorded treatment outcomes constitute new accuracy or response-prediction evidence.")
doc.add_paragraph("Strengths include primary-tumour matching across every data source, deterministic mean pooling of multiple slides, nested patient-level validation, FDR control within cancer and endpoint family, exact negative-result reporting, site-grouped sensitivity, saved research models and executable inference code. The supplied Bonneville spreadsheets contained only an ACC/CESC/MESO subset; cBioPortal PanCancer Atlas MANTIS fields were therefore used for full coverage and agreed exactly for all 387 overlapping cases.")
doc.add_paragraph("The principal limitation is absence of independent external validation. TCGA resampling, even with site separation, cannot establish transportability to another institution, scanner, stain distribution or patient population. The study is retrospective and exploratory; thresholds are prioritisation rules, not clinical operating points. Although TCGA was excluded from TITAN's Mass-340K pretraining corpus, it was used in the original paper's downstream evaluation; the present cohort is therefore neither a pretraining cohort nor an independent validation cohort. Predictability does not establish biological causality, and image-derived estimates cannot justify omitting a molecular assay. The three-model UCEC subset is locked only for future independent evaluation. Until that untouched analysis reports every target, the work should be evaluated as a computational pathology benchmark and research-software resource rather than a translational prediction study.")
doc.add_paragraph("CPTAC-UCEC illustrates both feasibility and the remaining work: the official collection provides pathology images and links to molecular data, but the approximately 154-GB slide archive requires de novo TITAN extraction and exact outcome harmonisation [36]. Neither the slides nor external labels were inspected here. The locked protocol prohibits model refitting, recalibration and threshold changes; mandates the same patient-level pooling; and requires failure or non-evaluability to be reported. This protocol improves readiness and guards against post hoc target selection, but it is not external validation evidence.")
doc.add_paragraph("The repeated nested-CV estimates and patient-cluster bootstrap intervals are also conditional on selecting endpoints in this same TCGA benchmark. They quantify partition and sampling variability for highlighted candidates but do not correct winner's-curse optimism from highlighting the strongest screen results. Consequently, the intervals should not be read as external-performance intervals; locked-model evaluation in an untouched cohort is required for unbiased transportability assessment.")
doc.add_paragraph("Arithmetic mean pooling gives each eligible slide equal weight and prevents multiple-slide leakage, but it does not model variable tissue area or within-patient morphological heterogeneity. The first-slide sensitivity measures dependence on one deterministic alternative and should not be interpreted as a comparison with learned or tissue-area-weighted aggregation.")
doc.add_paragraph("Demographic subgroup performance and algorithmic fairness were not evaluated. The TCGA Clinical Data Resource provides descriptive age, recorded gender, race and stage fields, but coverage and subgroup sizes vary across cancers and would fragment further under endpoint-specific molecular missingness. Tissue-source-site grouping probes one form of institutional heterogeneity but cannot establish fairness across ancestry, sex, age or access-to-care groups. Any external evaluation should prespecify representative sampling and subgroup performance, calibration and failure analysis.")

doc.add_heading("Conclusions", level=1)
doc.add_paragraph("Using mean-pooled fixed pretrained TITAN representations, this study provides a systematic patient-level TCGA benchmark of selected immune, mutation, pathway, MSI, aneuploidy and fusion phenotypes. The access-controlled TITANPred package demonstrates how fitted PLS and PLS–LDA objects can be applied without distributing patient-level training data. All reported performance and example outputs are internally derived TCGA estimates. The contribution is a transparent computational pathology benchmark and research-software framework—not broad endpoint novelty, external performance evidence or clinical validation—and locked independent testing remains essential.")

doc.add_heading("Abbreviations", level=1)
doc.add_paragraph(
    "AUROC, area under the receiver operating characteristic curve; BA, balanced "
    "accuracy; CV, cross-validation; FDR, false discovery rate; H&E, "
    "haematoxylin and eosin; LDA, linear discriminant analysis; MC3, Multi-Center "
    "Mutation Calling in Multiple Cancers; MSI, microsatellite instability; OOF, "
    "out-of-fold; PLS, partial least squares; PLS1, single-response PLS; PLS2, "
    "multi-response PLS; Q², cross-validated coefficient of determination; RMSE, "
    "root-mean-square error; TCGA, The Cancer Genome Atlas."
)

doc.add_heading("Declarations", level=1)
for h, text in [
    ("Ethics approval and consent to participate", "This secondary analysis used publicly available, de-identified TCGA data. No participants were recruited and no new tissue was collected."),
    ("Consent for publication", "Not applicable."),
    ("Study registration and protocol", "This retrospective secondary analysis was not registered. The locked executable analysis plan is available in the companion repository [30]."),
    ("Patient and public involvement", "Patients and members of the public were not involved in the design, conduct, interpretation or reporting of this secondary analysis."),
    ("Availability of data and materials", "The analysis used the gated public TITAN TCGA feature artifact TCGA_TITAN_features.pkl, downloaded from https://huggingface.co/MahmoodLab/TITAN/blob/main/TCGA_TITAN_features.pkl and converted to the documented 768-feature CSV schema with tools/convert_tcga_titan_pickle.py in the companion repository [30]. The analysed CSV contained 11,658 slide rows (SHA-256 d3d91fb0f83a6de440eda5ff437a63e3ca13f50095e6841fb8efcc40e58763f0). TCGA molecular data and the cited public supplementary records remain available from their original repositories. Exact source locations, access conditions and checksums are recorded in the companion repository. Controlled-access whole-slide images are not redistributed. The model registry, hashes, inference example and future external-evaluation protocol are in the public analysis repository. The separate TITANPred package and 323 fitted research objects are currently maintained in a private access-controlled repository [32]; this manuscript does not claim that those artifacts are publicly downloadable."),
    ("Competing interests", "[Author confirmation required before submission.]"),
    ("Funding", "[Author confirmation required before submission.]"),
    ("Authors’ contributions", "[Author initials and contribution statement required before submission.]"),
    ("Acknowledgements", "OpenAI Codex assisted with code refactoring and language editing. Human authors remain responsible for verification, interpretation and the submitted text."),
]:
    doc.add_heading(h, level=2); doc.add_paragraph(text)

doc.add_heading("Additional files", level=1)
doc.add_paragraph(
    "Additional file 1 (.docx): Supplementary material. Contains Supplementary "
    "Methods, Tables S1–S12, Figures S1–S2 and an inventory of the companion "
    "machine-readable result files."
)
doc.add_paragraph(
    "Additional file 2 (.pdf): COAD example A (TCGA-AA-A01F) TITANPred research-software output. "
    "Illustrative internally derived full-cohort TCGA estimates for the COAD example with "
    "high MSI, mutation-rate and immune-feature predictions and low aneuploidy prediction."
)
doc.add_paragraph(
    "Additional file 3 (.pdf): COAD example B (TCGA-AA-3972) TITANPred research-software output. "
    "Illustrative internally derived full-cohort TCGA estimates for the contrasting COAD "
    "example with high aneuploidy prediction and lower MSI and immune-feature predictions."
)

doc.add_heading("References", level=1)
references = [
"1. Coudray N, et al. Classification and mutation prediction from non-small cell lung cancer histopathology images using deep learning. Nat Med. 2018;24:1559–1567. doi:10.1038/s41591-018-0177-5.",
"2. Kather JN, et al. Deep learning can predict microsatellite instability directly from histology in gastrointestinal cancer. Nat Med. 2019;25:1054–1056. doi:10.1038/s41591-019-0462-y.",
"3. Echle A, et al. Clinical-grade detection of microsatellite instability in colorectal tumors by deep learning. Gastroenterology. 2020;159:1406–1416.e11. doi:10.1053/j.gastro.2020.06.021.",
"4. Fu Y, et al. Pan-cancer computational histopathology reveals mutations, tumor composition and prognosis. Nat Cancer. 2020;1:800–810. doi:10.1038/s43018-020-0085-8.",
"5. Kather JN, et al. Pan-cancer image-based detection of clinically actionable genetic alterations. Nat Cancer. 2020;1:789–799. doi:10.1038/s43018-020-0087-6.",
"6. Schmauch B, et al. A deep learning model to predict RNA-Seq expression of tumours from whole slide images. Nat Commun. 2020;11:3877. doi:10.1038/s41467-020-17678-4.",
"7. Howard FM, et al. The impact of site-specific digital histology signatures on deep learning model accuracy and bias. Nat Commun. 2021;12:4423. doi:10.1038/s41467-021-24698-1.",
"8. Loeffler CML, et al. Predicting mutational status of driver and suppressor genes directly from histopathology with deep learning. Front Genet. 2022;12:806386. doi:10.3389/fgene.2021.806386.",
"9. Dadhania V, et al. Leveraging artificial intelligence to predict ERG gene fusion status in prostate cancer. BMC Cancer. 2022;22:494. doi:10.1186/s12885-022-09559-4.",
"10. Mayer C, et al. Direct identification of ALK and ROS1 fusions in non-small cell lung cancer from hematoxylin and eosin-stained slides using deep learning algorithms. Mod Pathol. 2022;35:1882–1887. doi:10.1038/s41379-022-01141-4.",
"11. Saldanha OL, et al. Self-supervised attention-based deep learning for pan-cancer mutation prediction from histopathology. npj Precis Oncol. 2023;7:35. doi:10.1038/s41698-023-00365-0.",
"12. El Nahhas OSM, et al. Regression-based deep-learning predicts molecular biomarkers from pathology slides. Nat Commun. 2024;15:1253. doi:10.1038/s41467-024-45589-1.",
"13. Arslan S, et al. A systematic pan-cancer study on deep learning-based prediction of multi-omic biomarkers from routine pathology images. Commun Med. 2024;4:48. doi:10.1038/s43856-024-00471-5.",
"14. Bergstrom EN, et al. Deep learning artificial intelligence predicts homologous recombination deficiency and platinum response from histologic slides. J Clin Oncol. 2024;42:3550–3560. doi:10.1200/JCO.23.02641.",
"15. Patkar S, et al. Predicting the tumor microenvironment composition and immunotherapy response in non-small cell lung cancer from digital histopathology images. npj Precis Oncol. 2024;8:280. doi:10.1038/s41698-024-00765-w.",
"16. Ding T, et al. A multimodal whole-slide foundation model for pathology. Nat Med. 2025;31:3749–3761. doi:10.1038/s41591-025-03982-3.",
"17. Wold S, Sjöström M, Eriksson L. PLS-regression: a basic tool of chemometrics. Chemometr Intell Lab Syst. 2001;58:109–130. doi:10.1016/S0169-7439(01)00155-1.",
"18. Szymańska E, et al. Double-check: validation of diagnostic statistics for PLS-DA models. Metabolomics. 2012;8(Suppl 1):3–16. doi:10.1007/s11306-011-0330-3.",
"19. Thorsson V, et al. The Immune Landscape of Cancer. Immunity. 2018;48:812–830.e14. doi:10.1016/j.immuni.2018.03.023.",
"20. Taylor AM, et al. Genomic and functional approaches to understanding cancer aneuploidy. Cancer Cell. 2018;33:676–689.e3. doi:10.1016/j.ccell.2018.03.007.",
"21. Gao Q, et al. Driver fusions and their implications in the development and treatment of human cancers. Cell Rep. 2018;23:227–238.e3. doi:10.1016/j.celrep.2018.03.050.",
"22. Bonneville R, et al. Landscape of microsatellite instability across 39 cancer types. JCO Precis Oncol. 2017;2017:PO.17.00073. doi:10.1200/PO.17.00073.",
"23. Cerami E, et al. The cBio cancer genomics portal: an open platform for exploring multidimensional cancer genomics data. Cancer Discov. 2012;2:401–404. doi:10.1158/2159-8290.CD-12-0095.",
"24. Ellrott K, et al. Scalable open science approach for mutation calling of tumor exomes. Cell Syst. 2018;6:271–281.e7. doi:10.1016/j.cels.2018.03.002.",
"25. Bailey MH, et al. Comprehensive characterization of cancer driver genes and mutations. Cell. 2018;173:371–385.e18. doi:10.1016/j.cell.2018.02.060.",
"26. Sanchez-Vega F, et al. Oncogenic signaling pathways in The Cancer Genome Atlas. Cell. 2018;173:321–337.e10. doi:10.1016/j.cell.2018.03.035.",
"27. Benjamini Y, Hochberg Y. Controlling the false discovery rate: a practical and powerful approach to multiple testing. J R Stat Soc B. 1995;57:289–300. doi:10.1111/j.2517-6161.1995.tb02031.x.",
"28. Collins GS, et al. TRIPOD+AI statement: updated guidance for reporting clinical prediction models that use regression or machine learning methods. BMJ. 2024;385:e078378. doi:10.1136/bmj-2023-078378.",
"29. Liu J, et al. An integrated TCGA pan-cancer clinical data resource to drive high-quality survival outcome analytics. Cell. 2018;173:400–416.e11. doi:10.1016/j.cell.2018.02.052.",
f"30. TITAN patient-level benchmark repository. GitHub. {REPO}. Accessed 15 Aug 2026.",
"31. International Agency for Research on Cancer. Global Cancer Observatory: GLOBOCAN 2022 world fact sheet. Lyon: IARC; 2024. https://gco.iarc.who.int/media/globocan/factsheets/populations/900-world-fact-sheet.pdf. Accessed 16 Aug 2026.",
f"32. TITANPred R package and fitted-model repository. GitHub. {MODEL_REPO}. Accessed 16 Aug 2026.",
"33. National Cancer Institute. Genomic Data Commons Cases API. https://api.gdc.cancer.gov/cases. Accessed 16 Aug 2026.",
"34. Fernandes G. Morpho-genomic deep learning for ovarian cancer subtype and gene mutation prediction from histopathology. arXiv. 2025;arXiv:2511.03365. doi:10.48550/arXiv.2511.03365.",
"35. Wells K, Lamrca A, Papaxoinis G, et al. Unique correlation between GTF2I mutation and spindle cell morphology in thymomas (type A and AB thymomas). J Clin Pathol. 2023;76:463–466. doi:10.1136/jclinpath-2021-207837.",
"36. National Cancer Institute Clinical Proteomic Tumor Analysis Consortium. CPTAC-UCEC: The Clinical Proteomic Tumor Analysis Consortium Uterine Corpus Endometrial Carcinoma Collection. The Cancer Imaging Archive. doi:10.7937/K9/TCIA.2018.3R3JUISW. Accessed 24 Aug 2026.",
]
for ref in references: doc.add_paragraph(ref)
doc.save(OUT / "manuscript_JTM_patient_level_TITAN.docx")


# Supplementary document
sup = setup(Document(), "Supplementary material — TITAN benchmark")
sup.add_heading("Supplementary material", 0)
sup.add_paragraph(MANUSCRIPT_TITLE)
sup.add_paragraph("This document is Additional file 1. The COAD example A (TCGA-AA-A01F) and example B (TCGA-AA-3972) TITANPred research-software outputs are supplied as separate PDF attachments (Additional files 2 and 3, respectively).")
sup.add_heading("Supplementary Methods", 1)
sup.add_paragraph("The executable analysis plan, source manifest, eligibility catalogues, checkpoint-capable scripts and released out-of-fold prediction tables are available in the public companion analysis repository. The separate access-controlled TITANPred R package contains the fitted research models, model registry, reference distributions and research-software output template; it is currently private and is not claimed as a public artifact release. Large local restart checkpoints are not redistributed. Tables below are concise views; complete machine-readable CSV files are authoritative.")
sup.add_heading("Secondary PLS1–PLS2 inflammatory comparison", 2)
sup.add_paragraph("The secondary comparison jointly modelled three prespecified inflammatory blocks: infiltration/signatures, immune repertoire and inferred immune-cell fractions. Response-by-response PLS1 and joint PLS2 used identical complete-case patients and outer folds, training-fold outcome scaling, separately selected component counts and three independently seeded nested-CV repeats. Changes in Q² were aggregated first within cancer; uncertainty was estimated by resampling cancers. Endpoint win counts were not treated as inferential evidence.")
sup.add_heading("Table S1. Analysis coverage", 1)
add_table(sup, ["Family", "Type", "Tests", "Cancers", "Higher effect", "Moderate effect", "Screen-negative"], family_table)
if participant_characteristics:
    sup.add_heading("Table S2. Participant characteristics from the TCGA Clinical Data Resource", 1)
    sup.add_paragraph("Counts are descriptive source fields. Gender and race are reported using the CDR categories; W/B/A/O denote White, Black or African American, Asian and other recorded race. Stage combines available pathologic stage with clinical stage only when pathologic stage is unavailable. The full machine-readable table retains availability counts and broad race/stage components.")
    add_table(sup, ["Cancer", "n", "CDR matched", "Age, median (IQR)",
                    "Gender F/M/missing", "Race W/B/A/O/missing",
                    "Stage I/II/III/IV/missing"],
              [(r.get("tumor_type"), r.get("patients"), r.get("cdr_matched"),
                f'{fnum(r.get("age_median"), 1)} ({fnum(r.get("age_q1"), 1)}–{fnum(r.get("age_q3"), 1)})',
                f'{r.get("female")}/{r.get("male")}/{r.get("gender_missing")}',
                f'{r.get("race_white")}/{r.get("race_black_or_african_american")}/{r.get("race_asian")}/{r.get("race_other_recorded")}/{r.get("race_missing")}',
                f'{r.get("stage_I")}/{r.get("stage_II")}/{r.get("stage_III")}/{r.get("stage_IV")}/{r.get("stage_missing_or_other")}')
               for r in participant_characteristics])
sup.add_heading("Table S3. Slide multiplicity and report coverage by cancer", 1)
add_table(sup, ["Cancer", "Patients", "Slides", "Multi-slide patients", "Maximum slides", "Multiple primary barcodes", "Exact report matches"],
          [(r.get("tumor_type") or "Unresolved", r.get("patients"), r.get("eligible_slides"),
            r.get("multi_slide_patients"), r.get("maximum_slides_per_patient"),
            r.get("patients_with_multiple_primary_sample_barcodes"), r.get("exact_report_matched_slides"))
           for r in slide_multiplicity])
sup.add_heading("Table S4. Mutation molecular coverage by cancer", 1)
sup.add_paragraph(f"Across {len(mutation_eligibility):,} prespecified cancer–gene pairs, {n_mutation_eligible:,} were eligible, {sum(r.get('eligibility') == 'insufficient_positive' for r in mutation_eligibility):,} had fewer than 20 positive patients and {sum(r.get('eligibility') == 'insufficient_negative' for r in mutation_eligibility):,} had fewer than 20 negative patients. These ineligible pairs were not entered into model fitting or multiplicity correction.")
sup.add_paragraph("The machine-readable mutation_variant_classification_audit.csv lists every MC3 variant class observed in the modelling slot and whether it was retained under the explicit protein-altering definition.")
add_table(sup, ["Cancer", "Embedding patients", "MC3-profiled", "Missing MC3", "Multiple primary aliquots"],
          [(r.get("tumor_type"), r.get("titan_embedding_patients"), r.get("matched_profiled_patients"),
            r.get("embedding_patients_without_mc3_profile"), r.get("profiled_patients_with_multiple_primary_aliquots"))
           for r in mutation_coverage])
sup.add_heading("Table S5. Non-mutation molecular-source coverage", 1)
add_table(sup, ["Source", "Cohort patients", "Covered", "Missing", "Multiple primary aliquots", "Maximum aliquots", "Aggregation rule"],
          source_coverage_summary)
if highlighted:
    sup.add_heading("Table S6a. Highlighted-model performance and uncertainty", 1)
    performance_rows = []
    deployment_rows = []
    for r in highlighted:
        if r.get("outcome_type") == "binary":
            primary = (f'BA {fnum(r.get("balanced_accuracy"))} '
                       f'({fnum(r.get("balanced_accuracy_ci_low"))}–{fnum(r.get("balanced_accuracy_ci_high"))})')
            class_metrics = (f'Se {fnum(r.get("sensitivity"))} '
                             f'({fnum(r.get("sensitivity_ci_low"))}–{fnum(r.get("sensitivity_ci_high"))}); '
                             f'Sp {fnum(r.get("specificity"))} '
                             f'({fnum(r.get("specificity_ci_low"))}–{fnum(r.get("specificity_ci_high"))})')
            other = (f'AUROC {fnum(r.get("auc"))} '
                     f'({fnum(r.get("auc_ci_low"))}–{fnum(r.get("auc_ci_high"))})')
        else:
            primary = (f'Q² {fnum(r.get("q2"))} '
                       f'({fnum(r.get("q2_ci_low"))}–{fnum(r.get("q2_ci_high"))})')
            class_metrics = "Not applicable"
            other = (f'RMSE {fnum(r.get("rmse"))} '
                     f'({fnum(r.get("rmse_ci_low"))}–{fnum(r.get("rmse_ci_high"))}); '
                     f'ρ {fnum(r.get("spearman"))} '
                     f'({fnum(r.get("spearman_ci_low"))}–{fnum(r.get("spearman_ci_high"))})')
        performance_rows.append((
            r.get("outcome_type"), r.get("tumor_type") + "–" + r.get("endpoint"),
            r.get("n"), primary, class_metrics, other
        ))
        model_metadata = (f'{r.get("model_id")}; {r.get("ncomp")} components; '
                          f'fit seed {r.get("model_fit_seed")}; '
                          f'{r.get("feature_dimension")} features; '
                          f'{r.get("aggregation")}; transform: '
                          f'{r.get("endpoint_transform")}; output: '
                          f'{r.get("output_units")}')
        classification_metadata = "Not applicable"
        if r.get("outcome_type") == "binary":
            classification_metadata = (
                f'coding: {r.get("class_labels")}; priors: '
                f'{r.get("class_priors")}; rule: {r.get("prediction_rule")}; '
                f'calibration: {r.get("calibration_status")}'
            )
        provenance_metadata = (
            f'model SHA-256 prefix: {str(r.get("model_sha256"))[:12]}; '
            f'feature-schema SHA-256 prefix: '
            f'{str(r.get("feature_schema_sha256"))[:12]}; TITAN-file SHA-256 '
            f'prefix: {str(r.get("titan_feature_file_sha256"))[:12]}; fastPLS '
            f'{r.get("model_fastPLS_version")} '
            f'({str(r.get("model_fastPLS_remote_sha"))[:7]}), '
            f'{r.get("model_backend")}/{r.get("model_svd_method")}; '
            f'rSVD oversampling {r.get("model_rsvd_oversample")}, power '
            f'{r.get("model_rsvd_power")}; '
            f'analysis fingerprint prefix: '
            f'{str(r.get("model_analysis_fingerprint"))[:12]}; '
            f'external validation: '
            f'{r.get("external_validation")}; patient training rows retained: '
            f'{r.get("contains_patient_level_training_rows")}; '
            f'{r.get("redistribution_status")}'
        )
        deployment_rows.append((
            r.get("tumor_type") + "–" + r.get("endpoint"), model_metadata,
            classification_metadata, provenance_metadata
        ))
    add_table(sup, ["Type", "Cancer–endpoint", "n", "Primary metric (95% CI)",
                    "Sensitivity/specificity (95% CI)", "Other metrics (95% CI)"],
              performance_rows)
    sup.add_heading("Table S6b. Highlighted-model research-use and provenance metadata", 1)
    sup.add_paragraph(
        "Checksum prefixes are shown for readability; complete SHA-256 values are "
        "provided in highlighted_model_performance.csv and models/model_registry.csv."
    )
    add_table(sup, ["Cancer–endpoint", "Model and input", "Classification",
                    "Provenance and release status"], deployment_rows)
sup.add_heading("Table S6c. Prospectively locked subset for future independent evaluation", 1)
sup.add_paragraph("These three models were selected after the internal TCGA screen but before inspection of any external features, outcomes or predictions. The external analysis has not been performed. No refitting, recalibration, class-prior change, threshold adjustment or outcome optimisation is permitted. Every target must be reported, including failure or non-evaluability.")
add_table(
    sup,
    ["Order", "Target/type", "Model SHA-256", "Internal TCGA evidence", "External metrics", "Compatibility and reporting rule"],
    [(
        r["evaluation_order"], f'{r["cancer_type"]}–{r["endpoint"]} ({r["target_type"]})',
        r["model_sha256"],
        f'{r["internal_repeated_cv_primary"]}; {r["internal_repeated_cv_secondary"]}; {r["site_grouped_metric"]}',
        f'Primary: {r["locked_external_primary_metric"]}; secondary: {r["locked_external_secondary_metrics"]}',
        f'{r["endpoint_compatibility_rule"]}. {r["reporting_rule"]}. Status: {r["external_validation_status"]}.'
    ) for r in external_locked_targets],
)
sup.add_heading("Table S7. Top continuous results", 1)
add_table(sup, ["Cancer", "Endpoint", "Family", "n", "Q²", "q", "Category"],
          [(r["tumor_type"], r["endpoint"], r["family"], r["n"], fnum(r["q2"]), fnum(r["q_value"]), category(r["tier"])) for r in top_c[:60]])
sup.add_heading("Table S8. Top binary results", 1)
add_table(sup, ["Cancer", "Endpoint", "Family", "n", "Positive", "Balanced accuracy", "q", "Category"],
          [(r["tumor_type"], r["endpoint"], r["family"], r["n"], r["positive"], fnum(r["balanced_accuracy"]), fnum(r["q_value"]), category(r["tier"])) for r in top_b[:60]])
sup.add_heading("Table S9. Published exact cancer–gene results compared with the current screen", 1)
sup.add_paragraph("Prior studies predominantly reported AUROC, whereas the current prespecified metric is balanced accuracy. These values are displayed side by side for context but are not directly subtractable and do not constitute a head-to-head model comparison.")
add_table(sup, ["Study", "Cancer", "Gene", "Prior result", "Current BA", "Current q", "Current status"],
          [(r["study"], r["cancer"], r["gene"], r["prior_metric"], fnum(r["current_balanced_accuracy"]), fnum(r["current_q"]), r["current_status"].replace("_", " ")) for r in lit_accuracy])
sup.add_heading("Table S10a. Expanded literature audit for every screen-positive mutation predictor", 1)
sup.add_paragraph("The audit maps pooled colorectal cohorts to COAD and READ where appropriate and distinguishes prior statistical support, prior evaluation without support, and a result not identified in the reviewed predictive-model literature. The last category is not a claim of biological novelty or an exhaustive proof of bibliographic novelty.")
add_table(sup, ["Cancer", "Gene", "Evidence class", "Prior study/scope", "Prior result", "Current BA", "Current q", "Current category"],
          [(r["cancer"], r["gene"], r["evidence_class"],
            f'{r.get("prior_study")} / {r.get("prior_scope")}', r.get("prior_result"),
            fnum(r["current_balanced_accuracy"]), fnum(r["current_q"]), category(r["current_tier"]))
           for r in mutation_literature_audit])
sup.add_heading("Table S10b. Screen-positive models below the original effect threshold under site-grouped validation", 1)
add_table(sup, ["Type", "Family", "Cancer", "Endpoint", "n", "Sites", "Random-fold metric", "Site-grouped metric", "Delta"],
          [(r.get("outcome_type"), r.get("family"), r.get("tumor_type"), r.get("endpoint"),
            r.get("n"), r.get("n_sites"), fnum(r.get("original_metric")),
            fnum(r.get("site_grouped_metric")), fnum(r.get("delta")))
           for r in site_threshold_failures])
sup.add_heading("Table S10c. PLS versus exportable ridge benchmark for highlighted models", 1)
sup.add_paragraph("The benchmark is conditional on selection of PLS screen-positive highlighted models. Positive differences favour ridge; metrics and paired-repeat intervals should be interpreted by magnitude rather than winner counts.")
add_table(sup, ["Type", "Family", "Cancer", "Endpoint", "Metric", "PLS mean", "Ridge mean", "Ridge−PLS", "95% interval", "Interpretation"],
          [(r.get("outcome_type"), r.get("family"), r.get("tumor_type"), r.get("endpoint"),
            r.get("primary_metric"), fnum(r.get("pls_primary_mean")),
            fnum(r.get("ridge_primary_mean")), fnum(r.get("delta_ridge_minus_pls")),
            f'{fnum(r.get("delta_ci_low"))} to {fnum(r.get("delta_ci_high"))}',
            r.get("selected_method")) for r in ridge_comparison])
sup.add_heading("Table S11. Prior histology-based molecular and immune prediction landscape", 1)
add_table(sup, ["Study", "Year", "Scope", "Endpoints", "Development cohort", "External validation", "Reported performance", "DOI"],
          [(r.get("study"), r.get("year"), r.get("scope"), r.get("endpoints"),
            r.get("development_cohort"), r.get("external_validation"),
            r.get("reported_performance"), r.get("doi")) for r in literature_landscape])
sup.add_heading("Table S12. TRIPOD+AI reporting map", 1)
sup.add_paragraph("Items are mapped to the revised manuscript and repository using the official TRIPOD+AI checklist (version 11 January 2024). Pending entries require author or institutional information and are not statistical-analysis omissions.")
add_table(sup, ["Item", "Topic", "Reported location", "Status"],
          [(r.get("item"), r.get("topic"), r.get("reported_location"), r.get("status"))
           for r in tripod_map])
sup.add_heading("Secondary PLS1–PLS2 results", 1)
if pls2:
    text = []
    for r in pls2:
        text.append(f'{r["block"].replace("_", " ")}: mean cancer-level ΔQ² {fnum(r["mean_cancer_delta"])} (95% interval {fnum(r["ci_low"])} to {fnum(r["ci_high"])})')
    sup.add_paragraph("; ".join(text) + ". The intervals describe variation across cancers; interpretation is based on effect magnitude rather than endpoint win counts.")
add_figure(sup, "Figure6a_pls1_vs_pls2_targets.png", "Figure S1. Matched target-level PLS1 and PLS2 Q² on identical held-out patients.")
add_figure(sup, "Figure6b_pls1_vs_pls2_cancers.png", "Figure S2. Cancer-level mean Q² change for joint PLS2 relative to response-by-response PLS1.")
sup.add_heading("Machine-readable additional files", 1)
for name in ["continuous_screen.csv", "binary_screen.csv", "screen_positive_performance_summary.csv", "highlighted_model_performance.csv", "continuous_repeated_nested_cv.csv", "binary_repeated_nested_cv.csv", "continuous_repeated_oof_predictions.csv.gz", "binary_repeated_oof_predictions.csv.gz", "continuous_site_grouped_sensitivity.csv", "binary_site_grouped_sensitivity.csv", "site_grouped_retention_summary.csv", "site_grouped_models_below_effect_threshold.csv", "continuous_slide_pooling_sensitivity.csv", "binary_slide_pooling_sensitivity.csv", "pls1_vs_pls2_inflammation.csv", "ridge_baseline_repeated_nested_cv.csv", "pls_vs_ridge_highlighted_models.csv", "prior_mutation_literature_crosswalk.csv", "prior_mutation_accuracy_comparison.csv", "supported_mutation_literature_audit.csv", "pan_cancer_benchmark_comparison.csv", "external_validation_locked_targets.csv", "slide_report_coverage_audit.csv", "patient_slide_multiplicity_by_cancer.csv", "participant_characteristics_by_cancer.csv", "tcga_cdr_match_audit.csv", "molecular_source_coverage_audit.csv", "mutation_coverage_audit.csv", "mutation_target_eligibility_audit.csv", "mutation_variant_classification_audit.csv", "source_manifest.csv", "software_manifest.csv", "models/model_registry.csv"]:
    p = sup.add_paragraph(name, style="List Bullet")
    p.paragraph_format.space_after = Pt(0)
    p.paragraph_format.line_spacing = 1.2
sup.save(OUT / "supplementary_material_JTM.docx")


# Point-by-point response
resp = setup(Document(), "Response to reviewer — TITAN benchmark")
resp.add_heading("Response to reviewer", 0)
resp.add_paragraph("Manuscript: " + MANUSCRIPT_TITLE)
resp.add_paragraph("We thank the reviewer for identifying validation and reproducibility as the principal issues. The analysis has been rebuilt from the original files with patient-first slide aggregation and primary-tumour molecular matching.")

responses = [
    ("1. The novelty relative to existing pan-cancer studies must be defined much more sharply",
     "Agreed. We changed the title and abstract to frame the work as a systematic patient-level benchmark and reusable model resource, not a discovery atlas or a first pan-cancer molecular screen. The Background now quantifies the closest precedents: Fu et al. analysed 17,355 slides across 28 cancers; Kather et al. used more than 5,000 patients across 14 cancers; Saldanha et al. externally tested mutation models in seven matched TCGA/CPTAC cancers; and Arslan et al. trained 12,093 models for 4,031 biomarkers in 8,890 TCGA patients across the same 32 cancers. New main-text Table 1 compares patients, slides, endpoint classes, representation, patient aggregation, validation, site sensitivity, external validation, negative/ineligible reporting and fitted-predictor availability. The abstract and Discussion now state that 38/41 screen-positive cancer–gene pairs had prior statistical support. We make no general mutation-target novelty claim; the distinctive contribution is the fixed pretrained TITAN representation, deterministic pre-outcome patient aggregation, nested patient-level validation, complete negative and ineligible outputs, target-level site sensitivity, continuous immune/genomic-context modelling and compact fitted-model distribution. The comparison is also released as data/reference/pan_cancer_benchmark_comparison.csv."),
    ("Audit comment: continuous repeated cross-validation returned negative Q² and near-zero correlation",
     "Confirmed and corrected. fastPLS returns continuous predictions as an n-by-1-by-1 array. The previous repeated-validation helper used Ypred[[1]], which extracted one scalar and silently recycled it across every patient in the held-out fold. The revised helper drops only singleton dimensions, verifies that the prediction length equals the held-out patient count, and then assigns one prediction per patient. A targeted COAD TIL Regional Fraction check agreed with pls.double.cv (corrected Q² 0.430 and Spearman 0.701 versus 0.377 and 0.655 with the independent routine). We invalidated the affected analysis fingerprint and regenerated all repeated continuous predictions, summaries, uncertainty intervals, reference distributions, figures and reports. Across the 219 screen-positive continuous models, corrected mean repeated-CV Q² values are now positive, with median Q² 0.300 and median Spearman correlation 0.553."),
    ("Audit comment: continuous radar reference positions inherited the broken predictions",
     "Confirmed. The fitted full-cohort predictions were not affected, but the TCGA out-of-fold reference distributions used for radar positions were. TITANPred's prediction_reference.rds was rebuilt from the corrected repeated held-out predictions, the package was reinstalled, and the COAD reports and Figure 7 were regenerated. The original model prediction remains printed at every radar corner."),
    ("Audit comment: site-grouped validation was underreported",
     f"Addressed. We now report both the median change and threshold retention. {ival(site_combined.get('below_threshold_models'))}/{ival(site_combined.get('screen_positive_models'))} screen-positive models ({fnum(site_combined.get('below_threshold_percent'), 1)}%) fell below the original effect threshold under hospital-grouped folds: 58/219 continuous and 25/104 binary models. Named examples include READ–APC (balanced accuracy 0.862 to 0.495), COAD–APC (0.793 to 0.543), and COAD–SNV Neoantigens (Q² 0.239 to −0.013). The text acknowledges that smaller and uneven grouped training folds explain part of the decrease but treats near-chance APC results as site-sensitive. Complete target-level results are added as Table S10b and CSV."),
    ("Audit comment: mutation novelty was overstated",
     f"Confirmed. The exact-code crosswalk missed pooled colorectal studies and did not include newer pan-cancer source data. We expanded the audit using Kather et al., Saldanha et al., Arslan et al. and a clearly labelled ovarian preprint. Of {len(mutation_literature_audit)} screen-positive mutation pairs, {len(prior_supported_mutations)} were previously supported, {len(prior_evaluated_not_supported)} had been evaluated without statistical support, and only THYM–GTF2I was not identified in the reviewed predictive-model literature. All 'atlas-nominated' novelty language was removed. The revised Table S10a records evidence class, cancer scope, prior metric, source and note for every pair."),
    ("Audit comment: PLS lacked a simple exportable baseline",
     "Addressed with a same-fold repeated nested benchmark of the 24 highlighted models against ridge Gaussian or logistic regression. Median ridge-minus-PLS differences were 0.014 Q² for continuous and 0.007 balanced accuracy for binary models. Paired intervals favoured ridge for seven continuous and two binary models, PLS for two continuous and one binary model, and were uncertain for the remaining 12. We therefore state that PLS is competitive but not uniformly superior. Because the benchmark is conditional on PLS-based endpoint highlighting, the prespecified PLS workflow is retained rather than adding post-selection method switching. Ridge was selected as the baseline because its fitted coefficients are portable without retaining training embeddings; the full repeated results and uncertainty are supplied in Table S10c and CSV."),
    ("Audit comment: the Introduction did not state the gap",
     "Addressed. The Background now states explicitly that breadth is not the gap after the large pan-cancer studies by Fu, Kather, Saldanha and especially Arslan. It defines the narrower gap as a reproducible patient-level benchmark using one fixed pretrained representation, deterministic slide aggregation, one nested validation framework, complete negative and ineligible reporting, target-level site sensitivity and compact fitted research models."),
    ("Audit comment: binary percentiles could be mistaken for probabilities and small classes were not visible",
     "Addressed by relabelling rather than adding an unevaluated post-hoc calibration layer. Binary displays and tables now use 'TCGA out-of-fold score rank (not probability)', retain the raw uncalibrated LDA score and class call, and show training n, positive and negative counts, prevalence, repeated-CV balanced accuracy and AUROC. A warning is emitted and printed when either development class contains fewer than 50 patients. The 20-per-class modelling eligibility rule is unchanged. Proper probability calibration remains future work requiring independently evaluated or fully nested calibration."),
    ("1. Across-cancer multiplicity and permutation resolution",
     f"Addressed. Every effect-eligible endpoint is refined toward 999 patient-label permutations with a conservative stopping boundary of 49 exceedances, minimum completed-test resolution 0.001, and exact attempted counts retained. Both the prespecified within-cancer family q-value and the stricter across-cancer family q-value are reported. The abstract, figures and Discussion state that {len(global_supported_c)} continuous and {len(global_mutation_b)} cancer–mutation pairs passed the stricter correction; all remaining within-cancer results are framed as cancer-specific discovery candidates. We now also state explicitly that the 0.001 resolution limits attainable q-values in large global families, so non-passage is not evidence of absence."),
    ("2. External validation is the principal unresolved limitation",
     "We agree that this is the central unresolved limitation. The official TITAN release provided the TCGA embeddings used here, but our audit found no compatible non-TCGA precomputed TITAN representation with the required outcomes; no independent patient entered analysis. CPTAC-UCEC is a realistic future cohort because its official TCIA collection reports 250 subjects, 887 pathology slides (approximately 154 GB) and linked molecular resources, but de novo TITAN extraction and exact endpoint harmonisation are required and were not performed. We therefore adopted the reviewer's computational-resource fallback throughout: 'deployment', 'patient molecular profile' and 'prediction report' language was removed; Figure 7 is a 'research-software demonstration'; and all numerical outputs are labelled internally derived TCGA estimates. The abstract, intended use, Discussion and Conclusions state that there is no external performance evidence or basis for clinical interpretation. To prevent future target or threshold cherry-picking, we prospectively locked three UCEC artifacts before inspecting any external features or outcomes: TP53 mutation, genome doubling and continuous aneuploidy score. Their exact SHA-256 hashes, endpoint-compatibility rules and metrics are in new main-text Table 4, Supplementary Table S6c, docs/EXTERNAL_VALIDATION_PROTOCOL.md and data/reference/external_validation_locked_targets.csv. The future protocol requires exact TITAN extraction, identical patient pooling, no refitting, recalibration or threshold adjustment, and reporting of every target including failures and non-evaluable endpoints. We explicitly state that locking a protocol is not external validation."),
    ("3. Site robustness is incomplete for the inflammatory atlas",
     f"Addressed. Tissue-source-site-grouped validation is now attempted for every within-cancer screen-positive continuous and binary endpoint, not only mutations. It was feasible for {sum(r.get('feasible')=='TRUE' for r in site_c)+sum(r.get('feasible')=='TRUE' for r in site_b)} models. Figure 6 and the complete machine-readable tables report target-level attenuation; the manuscript does not claim that repeated random folds exclude site confounding."),
    ("4. Reproducibility materials must be deposited before submission",
     f"The analysis repository ({REPO}) remains public and contains the analysis plan, source URLs/checksums, software commit, eligibility tables, code, out-of-fold outputs, literature crosswalk, model registry and locked external-evaluation protocol. At the authors' request, the TITANPred repository ({MODEL_REPO}) is now private. The manuscript no longer claims that the package or 323 fitted objects are publicly downloadable. A public model release, if permitted, and a persistent DOI remain future release decisions; reviewers can be granted controlled access when authorised."),
    ("5. Distinguish cancer genes from functional driver alleles",
     "Addressed throughout. Mutation targets are described as qualifying protein-altering PASS mutations in tissue-specific consensus cancer genes; the manuscript explicitly states that not every allele is functionally validated."),
    ("6. Preserve effect-size-first interpretation of PLS2",
     "Addressed. The PLS1–PLS2 comparison is now confined to the Supplementary Methods, results and Figures S1–S2. It remains restricted to coherent inflammatory blocks, uses identical patients and folds, and is interpreted by cancer-level ΔQ² with bootstrap intervals rather than win counts. Binary molecular endpoints retain one-at-a-time PLS–LDA as the primary analysis."),
    ("7. Complete submission-specific fields",
     "Partly outstanding. Aamilah Ismail and Martin Ocharo are listed as shared co-first authors, with Martin Ocharo second in the author order and assigned to affiliations 1 and 2. Brendon Price is included in the middle of the author list with the Division of Anatomical Pathology, University of Cape Town and National Health Laboratory Service affiliation. Silvano Piazza and Dinesh Gupta are listed immediately before Stefano Cacciatore. Silvano Piazza has dual affiliations with the ICGEB Computational Biology Group in Trieste and the Bioinformatics Facility, CIBIO, University of Trento; Dinesh Gupta has the ICGEB New Delhi affiliation. The remaining supplied author names, affiliations, available email addresses and corresponding-author details have been entered. Email addresses for Martin Ocharo, Brendon Price, Ekene Emmanuel Nweke, Silvano Piazza and Dinesh Gupta were not supplied. Funding, competing interests and contribution statements still require author confirmation and remain visibly marked where applicable. No scientific values are placeholder text."),
    ("8. Presentation and algorithm-comparison claims",
     "Addressed. High-resolution figures and machine-readable tables accompany the Word documents. Runtime and speed claims were removed. A focused same-fold ridge benchmark was added because it directly tests whether PLS materially outperforms a simpler portable linear model; it is reported with effect magnitudes, uncertainty and selection-conditioning caveats."),
    ("Additional change: distinguish replication from predictors not identified in the reviewed literature",
     "The Discussion uses an expanded primary-study audit, maps pooled colorectal evidence to COAD and READ, gives prior AUROC and current balanced accuracy side by side without treating the metrics as directly comparable, and distinguishes previously supported, previously evaluated-but-not-supported, and not-identified categories. Only THYM–GTF2I was not identified in the reviewed predictive-model literature, and even that result is not claimed as biological or definitive bibliographic novelty. The broader landscape audit covers MSI, continuous biomarkers, expression, gene fusion, HRD and tumour-microenvironment prediction, including external-validation examples."),
    ("Additional change: clarify model portability without training-data release",
     "The Background, Methods, Discussion and Conclusions explain that fitted PLS and PLS–LDA models contain compact learned transformations and coefficients and can be applied without distributing patient-level training embeddings or outcomes. Licensing, privacy, governance and external-validation limitations are retained."),
    ("Additional change: multiple slides and molecular specimen matching",
     f"The primary predictor is now the feature-wise mean of every eligible diagnostic slide per patient; {n_multi:,} multi-slide patients are retained in a single validation fold. We also audited every molecular source and excluded non-primary TCGA sample types before aggregation. A matched first-slide sensitivity quantifies dependence on the pooling rule."),
    ("Additional change: molecular missingness, wild-type status and aliquots",
     f"Mutation wild type is now assigned only among {n_mc3_profiled:,} patients matched to an MC3 primary-tumour profile; {n_mc3_missing:,} embedding patients without a profile are excluded. The nine accepted protein-altering MC3 variant classes are explicit and a cancer-level variant-class audit is released. Fusion negatives are defined only within the study sample list. Source-specific missingness, multiple aliquots and aggregation rules are written to audit tables and reported in Methods and Supplementary Material."),
    ("Additional change: TITAN pretraining and TCGA relationship",
     "The manuscript now documents that the published Mass-340K pretraining corpus excluded TCGA and PANDA, while TCGA was used for downstream evaluation in the original TITAN study. We therefore describe this work as a secondary TCGA benchmark and model resource, neither a pretraining-overlap analysis nor independent external validation."),
    ("Additional change: complete performance and prediction examples",
     "Highlighted binary models now report sensitivity, specificity, balanced accuracy and AUROC; highlighted continuous models report Q², RMSE and Spearman correlation, with patient-cluster bootstrap intervals. Research-use provenance includes feature checksums and ranges, class coding and priors, decision rule, calibration status, external-validation status and intended use. Figure 4 compares held-out predictions directly with observed data. The two illustrative COAD research-software outputs are supplied as separate PDF attachments (Additional files 2 and 3) and are labelled internally derived TCGA estimates."),
    ("Additional change: rSVD-only PLS decomposition",
     "All primary, permutation, repeated, site-grouped, slide-pooling, PLS1–PLS2 and final-model fits use CPU rSVD with 10 oversampling vectors, two power iterations and fixed seeds. Solver identity and controls are recorded in screening, sensitivity and model-registry metadata and verified against saved-model diagnostics."),
    ("Additional change: terminology and global multiplicity",
     f"Tier labels are replaced in the narrative and display headings by within-cancer higher-effect, moderate-effect and screen-negative categories. The abstract, Results and Discussion report explicitly that {len(global_supported_c)} continuous and {len(global_mutation_b)} cancer–mutation pairs passed the stricter across-cancer correction."),
    ("Additional change: TRIPOD+AI and fairness reporting",
     "Supplementary Table S12 maps every TRIPOD+AI item to the manuscript or repository. Participant characteristics from the TCGA Clinical Data Resource are now reported overall and by cancer; the Methods and Discussion state that no resampling or calibrated probability output was used, no formal power calculation was performed, treatment endpoints were not modelled, and demographic subgroup performance was not evaluated. Tissue-source-site sensitivity is not presented as a substitute for representative external subgroup evaluation."),
    ("Additional change: selection-conditioned uncertainty",
     "The Discussion now states that repeated nested-CV estimates and patient-cluster bootstrap intervals are conditional on endpoint selection in the same TCGA benchmark. They do not remove winner's-curse optimism and are not presented as external-performance intervals."),
]
for title, answer in responses:
    resp.add_heading(title, 1); resp.add_paragraph(answer)
resp.save(OUT / "response_to_reviewer_JTM.docx")

for source_name, output_name in (
    ("COAD_example_A.pdf", "Additional_file_2_COAD_example_A_TITANPred_report.pdf"),
    ("COAD_example_B.pdf", "Additional_file_3_COAD_example_B_TITANPred_report.pdf"),
):
    shutil.copyfile(ROOT / "results" / "reports" / source_name, OUT / output_name)

print(OUT / "manuscript_JTM_patient_level_TITAN.docx")
print(OUT / "supplementary_material_JTM.docx")
print(OUT / "response_to_reviewer_JTM.docx")
