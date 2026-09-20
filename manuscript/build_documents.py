#!/usr/bin/env python3
"""Build the JTM manuscript, supplement and point-by-point response from results."""
from __future__ import annotations

import csv
import os
import re
import shutil
import statistics
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
    "PATHOFM_MODEL_REPOSITORY_URL", "https://github.com/tkcaccia/PathoFMPred"
)
MANUSCRIPT_TITLE = (
    "Patient-level comparison of three released pathology representation pipelines "
    "with a common PLS-based probe across TCGA cancers"
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


def fnum_zero(x, digits=3):
    """Format numerical zero without a misleading negative sign."""
    try:
        value = float(x)
        if abs(value) < 0.5 * 10 ** (-digits):
            value = 0.0
        return f"{value:.{digits}f}"
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
    for name, size, color in [("Title", 20, "000000"), ("Heading 1", 15, "000000"),
                              ("Heading 2", 12, "000000"), ("Heading 3", 10.5, "000000")]:
        st = styles[name]; st.font.name = "Arial"; st.font.size = Pt(size)
        st.font.color.rgb = RGBColor.from_string(color); st.font.bold = True
        st.paragraph_format.line_spacing = 2.0
    styles["Caption"].font.name = "Arial"; styles["Caption"].font.size = Pt(9)
    styles["Caption"].font.italic = True
    header = sec.header.paragraphs[0]
    header.text = title or "Patient-level pathology foundation-model atlas"
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


def add_table(doc, headers, data, widths=None, trailing_paragraph=True,
              font_size=8, header_font_size=8.5, line_spacing=None,
              fixed_layout=False):
    table = doc.add_table(rows=1, cols=len(headers))
    table.alignment = WD_TABLE_ALIGNMENT.CENTER; table.style = "Table Grid"
    if fixed_layout:
        table.autofit = False
        tbl_pr = table._tbl.tblPr
        layout = OxmlElement("w:tblLayout")
        layout.set(qn("w:type"), "fixed")
        tbl_pr.append(layout)
    for i, h in enumerate(headers):
        cell = table.rows[0].cells[i]; cell.text = str(h)
        for r in cell.paragraphs[0].runs: r.font.bold = True; r.font.size = Pt(header_font_size)
        if line_spacing is not None:
            cell.paragraphs[0].paragraph_format.line_spacing = line_spacing
            cell.paragraphs[0].paragraph_format.space_after = Pt(0)
    header_pr = table.rows[0]._tr.get_or_add_trPr()
    repeat = OxmlElement("w:tblHeader"); repeat.set(qn("w:val"), "true")
    header_pr.append(repeat)
    for row in data:
        cells = table.add_row().cells
        for i, val in enumerate(row):
            display_val = str(val).replace("GigaSSL", "Giga-SSL").replace("ProvGigaPath", "Prov-GigaPath")
            display_val = display_val.replace("within-cancer screen-positive, prespecified screening tier", "within-cancer screening tier")
            display_val = display_val.replace("within-cancer screen-positive, predefined screening tier", "within-cancer screening tier")
            display_val = display_val.replace("original prespecified screening threshold", "original documented screening threshold")
            display_val = display_val.replace("original predefined screening threshold", "original documented screening threshold")
            display_val = display_val.replace("Prespecified atlas eligibility", "Documented atlas eligibility")
            display_val = display_val.replace("prespecified report terms", "fixed report terms")
            cells[i].text = display_val; cells[i].vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
            for p in cells[i].paragraphs:
                for r in p.runs: r.font.size = Pt(font_size)
                if line_spacing is not None:
                    p.paragraph_format.line_spacing = line_spacing
                    p.paragraph_format.space_after = Pt(0)
    for row in table.rows:
        row_pr = row._tr.get_or_add_trPr()
        no_split = OxmlElement("w:cantSplit")
        row_pr.append(no_split)
    if widths:
        for row in table.rows:
            for i, width in enumerate(widths): row.cells[i].width = Cm(width)
        if fixed_layout:
            table.alignment = WD_TABLE_ALIGNMENT.LEFT
            twips = [int(round(float(width) / 2.54 * 1440)) for width in widths]
            tbl_pr = table._tbl.tblPr
            tbl_w = tbl_pr.find(qn("w:tblW"))
            if tbl_w is None:
                tbl_w = OxmlElement("w:tblW")
                tbl_pr.append(tbl_w)
            tbl_w.set(qn("w:type"), "dxa")
            tbl_w.set(qn("w:w"), str(sum(twips)))
            tbl_ind = tbl_pr.find(qn("w:tblInd"))
            if tbl_ind is None:
                tbl_ind = OxmlElement("w:tblInd")
                tbl_pr.append(tbl_ind)
            tbl_ind.set(qn("w:type"), "dxa")
            tbl_ind.set(qn("w:w"), "0")
            tbl_grid = table._tbl.tblGrid
            for child in list(tbl_grid):
                tbl_grid.remove(child)
            for width_twips in twips:
                grid_col = OxmlElement("w:gridCol")
                grid_col.set(qn("w:w"), str(width_twips))
                tbl_grid.append(grid_col)
            for row in table.rows:
                for i, cell in enumerate(row.cells):
                    tc_pr = cell._tc.get_or_add_tcPr()
                    tc_w = tc_pr.find(qn("w:tcW"))
                    if tc_w is None:
                        tc_w = OxmlElement("w:tcW")
                        tc_pr.append(tc_w)
                    tc_w.set(qn("w:type"), "dxa")
                    tc_w.set(qn("w:w"), str(twips[i]))
    if trailing_paragraph:
        doc.add_paragraph()
    return table


def add_figure(doc, filename, caption, width=6.35):
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.add_run().add_picture(str(FIGURES / filename), width=Inches(width))
    c = doc.add_paragraph(caption, style="Caption"); c.alignment = WD_ALIGN_PARAGRAPH.CENTER


def display_representation(value):
    return {"GigaSSL": "Giga-SSL", "ProvGigaPath": "Prov-GigaPath"}.get(value, value)


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


def add_portrait_section(doc, section_start=WD_SECTION.NEW_PAGE):
    sec = doc.add_section(section_start)
    # python-docx represents the section boundary as an otherwise empty
    # paragraph.  Keep that boundary line minimal so a full-width landscape
    # table cannot push it onto an otherwise blank intermediary page.
    boundary = doc.paragraphs[-1]
    boundary.paragraph_format.space_before = Pt(0)
    boundary.paragraph_format.space_after = Pt(0)
    boundary.paragraph_format.line_spacing = Pt(1)
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


def remove_em_dashes(document):
    """Replace em dashes in reader-facing text with conventional punctuation."""
    for text_node in document.element.body.iter(qn("w:t")):
        if text_node.text and "—" in text_node.text:
            text_node.text = re.sub(r"\s*—\s*", ", ", text_node.text)


def replace_reader_facing_chronology_terms(document):
    """Keep development chronology out of the scientific narrative."""
    replacements = (
        ("revision-added primary matched benchmark", "retrospective matched benchmark"),
        ("revision-added matched three-representation benchmark", "retrospective matched three-representation benchmark conducted with documented analysis settings"),
        ("revision-added matched benchmark", "retrospective matched benchmark"),
        ("Revision-added", "Retrospective"),
        ("revision-added", "retrospective"),
        ("inferentially qualified TITAN layer", "permutation/FDR-filtered internal TITAN screen"),
        ("inferentially qualified TITAN analyses", "permutation/FDR-filtered internal TITAN screen"),
        ("inferentially qualified TITAN screen", "permutation/FDR-filtered internal TITAN screen"),
        ("TITAN-only inferential screen", "permutation/FDR-filtered internal TITAN screen"),
        ("secondary TITAN inferential layer", "permutation/FDR-filtered internal TITAN screen"),
        ("Secondary TITAN inferential layer", "Permutation/FDR-filtered internal TITAN screen"),
        ("secondary TITAN inferential screen", "permutation/FDR-filtered internal TITAN screen"),
        ("secondary TITAN layer", "permutation/FDR-filtered internal TITAN screen"),
    )
    for text_node in document.element.body.iter(qn("w:t")):
        if not text_node.text:
            continue
        for old, new in replacements:
                text_node.text = text_node.text.replace(old, new)


def standardize_matched_evidence_terms(document):
    """Use descriptive matched-atlas terminology consistently."""
    replacements = (
        ("primary-partition union-positive", "primary-partition effect-threshold-crossing"),
        ("primary union-positive", "primary effect-threshold-crossing"),
        ("union-positive or near-threshold", "effect-threshold-crossing or near-threshold"),
        ("union-positive tasks", "tasks with an effect-threshold crossing in at least one representation"),
        ("union-positive pairs", "pairs with an effect-threshold crossing in at least one representation"),
        ("union-positive cancer-endpoint pairs", "cancer-endpoint pairs with an effect-threshold crossing in at least one representation"),
        ("union-positive cancer–endpoint pairs", "cancer–endpoint pairs with an effect-threshold crossing in at least one representation"),
        ("union-positive", "effect-threshold-crossing"),
        ("descriptive crossing", "descriptive effect-threshold crossing"),
        ("performance-threshold crossing", "effect-threshold crossing"),
        ("performance-threshold crossings", "effect-threshold crossings"),
    )
    for text_node in document.element.body.iter(qn("w:t")):
        if not text_node.text:
            continue
        for old, new in replacements:
            text_node.text = text_node.text.replace(old, new)


def standardize_released_pipeline_terms(document):
    """Describe the evaluated artifacts as complete released representation pipelines."""
    replacements = (
        ("released pathology embedding pipelines", "released pathology representation pipelines"),
        ("released embedding pipelines", "released representation pipelines"),
        ("released embedding pipeline", "released representation pipeline"),
        ("complete released pipelines", "complete released representation pipelines"),
        ("three released pipelines", "three released representation pipelines"),
        ("embedding-pipeline-probe", "representation-pipeline-probe"),
        ("embedding-pipeline and probe", "representation-pipeline and probe"),
    )
    for text_node in document.element.body.iter(qn("w:t")):
        if not text_node.text:
            continue
        for old, new in replacements:
            text_node.text = text_node.text.replace(old, new)


def standardize_tissue_source_site_terms(document):
    """Use the exact barcode-variable name and avoid implying a physical site."""
    replacements = (
        ("TCGA tissue-source-site-code", "TCGA tissue-source-site code"),
        ("tissue-source-site-code", "TCGA tissue-source-site code"),
        ("TCGA TCGA tissue-source-site code", "TCGA tissue-source-site code"),
    )
    for text_node in document.element.body.iter(qn("w:t")):
        if not text_node.text:
            continue
        for old, new in replacements:
                text_node.text = text_node.text.replace(old, new)


def standardize_sample_size_maturity_terms(document):
    """Use denominator-based language without implying an evidence grade."""
    replacements = (
        ("larger-sample-stratum", "larger sample-size maturity stratum"),
        ("smaller-sample-stratum", "smaller sample-size maturity stratum"),
        ("larger-sample stratum", "larger sample-size maturity stratum"),
        ("smaller-sample stratum", "smaller sample-size maturity stratum"),
        ("larger sample stratum", "larger sample-size maturity stratum"),
        ("smaller sample stratum", "smaller sample-size maturity stratum"),
        ("sample-size stratum", "sample-size maturity stratum"),
        ("Sample-size strata", "Sample-size maturity strata"),
    )
    for text_node in document.element.body.iter(qn("w:t")):
        if not text_node.text:
            continue
        for old, new in replacements:
                text_node.text = text_node.text.replace(old, new)


def standardize_literature_audit_terms(document):
    """Label the non-systematic crosswalk consistently and transparently."""
    replacements = (
        ("targeted narrative mutation cross-check", "targeted narrative mutation audit"),
        ("targeted narrative cross-check", "targeted narrative audit"),
        ("targeted literature cross-check", "targeted narrative literature audit"),
        ("Targeted literature cross-check", "Targeted narrative literature audit"),
    )
    for text_node in document.element.body.iter(qn("w:t")):
        if not text_node.text:
            continue
        for old, new in replacements:
            text_node.text = text_node.text.replace(old, new)


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
site_fold_composition = rows("site_grouped_fold_composition_summary.csv")
site_fold_details = rows("site_grouped_outer_fold_composition.csv")
site_predictability = rows("tissue_source_site_predictability_summary.csv")
site_partition_controls = optional_rows("tissue_source_site_partition_controls.csv")
site_partition_summary = optional_rows("tissue_source_site_partition_controls_summary.csv")
ridge_comparison = rows("pls_vs_ridge_representative_models.csv")
ridge_jobs = rows("pls_vs_ridge_representative_jobs.csv")
ridge_stratified = rows("pls_vs_ridge_representative_stratified_summary.csv")
external_locked_targets = reference_rows("external_validation_locked_targets.csv")
outcome_source_acquisition = reference_rows("outcome_source_acquisition_map.csv")
ridge_summary = rows("pls_vs_ridge_representative_summary.csv")
permutation_uncertainty = rows("permutation_monte_carlo_uncertainty.csv")
multiplicity_summary = rows("multiplicity_sensitivity_summary.csv")
multiplicity_by_endpoint = rows("multiplicity_sensitivity_by_endpoint.csv")
multiplicity_p_assignment = rows("multiplicity_p_assignment_summary.csv")
multiplicity_denominators = rows("multiplicity_denominator_summary.csv")
targeted_permutation = optional_rows("targeted_permutation_refinement.csv")
highlighted = optional_rows("highlighted_model_performance.csv")
if highlighted:
    required_site_fields = {
        "site_grouped_metric_name", "site_grouped_metric", "site_grouped_n_sites",
        "site_performance_delta", "site_robustness_status",
        "site_grouped_inner_site_separation",
    }
    missing_site_fields = sorted(required_site_fields - set(highlighted[0]))
    if missing_site_fields:
        raise RuntimeError(
            "highlighted_model_performance.csv is from an incomplete build: missing "
            + ", ".join(missing_site_fields)
            + ". Run R/07f_attach_site_metadata.R after regenerating performance tables."
        )
binary_reliability = optional_rows("binary_class_reliability_summary.csv")
binary_class_sensitivity = optional_rows("binary_minimum_class_sensitivity.csv")
binary_limited = optional_rows("binary_limited_evidence_models.csv")
binary_fold_counts = optional_rows("binary_outer_fold_class_counts.csv")
binary_component_summary = optional_rows("binary_selected_component_distribution.csv")
binary_learning = optional_rows("binary_limited_evidence_learning_curve_summary.csv")
binary_decision_rule = optional_rows("binary_decision_rule_sensitivity.csv")
binary_decision_summary = optional_rows("binary_decision_rule_sensitivity_summary.csv")
binary_decision_changes = optional_rows("binary_decision_rule_membership_changes.csv")
binary_decision_folds = optional_rows("binary_decision_rule_fold_thresholds.csv")
foundation_binary_auroc_tuned = rows("foundation_model_binary_auroc_tuned_sensitivity.csv")
foundation_binary_auroc_summary = rows("foundation_model_binary_auroc_tuned_summary.csv")
foundation_binary_estimand = rows("foundation_model_binary_estimand_comparison.csv")
foundation_binary_operating_summary = rows(
    "foundation_model_binary_operating_rule_paired_summary.csv"
)
continuous_reliability = optional_rows("continuous_reliability_by_model.csv")
continuous_reliability_bands = optional_rows("continuous_reliability_by_sample_size.csv")
continuous_evidence_summary = optional_rows("continuous_evidence_category_summary.csv")
continuous_limited = optional_rows("continuous_limited_evidence_models.csv")
continuous_components = optional_rows("continuous_selected_components_by_fold.csv")
continuous_reliability_associations = optional_rows("continuous_reliability_association_summary.csv")
slide_coverage = optional_rows("slide_report_coverage_audit.csv")
slide_multiplicity = optional_rows("patient_slide_multiplicity_by_cancer.csv")
pathology_qc_fields = optional_rows("pathology_qc_field_availability.csv")
pathology_qc_mentions = optional_rows("pathology_qc_narrative_audit.csv")
pathology_qc_max = optional_rows("pathology_qc_maximum_slide_patient.csv")
pathology_qc_no_residual_patients = optional_rows("pathology_qc_no_residual_patient_audit.csv")
pathology_qc_no_residual_summary = optional_rows("pathology_qc_no_residual_patient_summary.csv")
no_residual_exclusion = optional_rows("nonadjudicated_no_residual_exclusion_all.csv")
no_residual_exclusion_summary = optional_rows("nonadjudicated_no_residual_exclusion_summary.csv")
no_residual_exclusion_highlighted = optional_rows("nonadjudicated_no_residual_exclusion_highlighted.csv")
mutation_coverage = optional_rows("mutation_coverage_audit.csv")
mutation_eligibility = optional_rows("mutation_target_eligibility_audit.csv")
molecular_coverage = optional_rows("molecular_source_coverage_audit.csv")
molecular_slide_linkage = optional_rows("molecular_slide_linkage_audit.csv")
median_pool_c = optional_rows("continuous_median_pooling_sensitivity.csv")
median_pool_b = optional_rows("binary_median_pooling_sensitivity.csv")
median_pool_summary = optional_rows("median_pooling_sensitivity_summary.csv")
slide_heterogeneity = optional_rows("slide_embedding_heterogeneity_summary.csv")
slide_heterogeneity_extreme = optional_rows("slide_embedding_heterogeneity_maximum_slide_patient.csv")
sarc_exclusion_c = optional_rows("sarc_maximum_slide_patient_exclusion_continuous.csv")
sarc_exclusion_b = optional_rows("sarc_maximum_slide_patient_exclusion_binary.csv")
participant_characteristics = optional_rows("participant_characteristics_by_cancer.csv")
subgroup_performance = optional_rows("subgroup_performance_audit.csv")
subgroup_summary = optional_rows("subgroup_performance_summary.csv")
subgroup_contrasts = optional_rows("subgroup_performance_contrast_summary.csv")
coad_examples = optional_rows("coad_package_examples.csv")
coad_example_predictions = optional_rows("coad_package_example_predictions.csv")
coad_multifoundation_predictions = optional_rows(
    "coad_pathofmpred_multifoundation_predictions.csv"
)
endpoint_dictionary = rows("endpoint_dictionary.csv")
endpoint_definitions = rows("endpoint_definition_dictionary.csv")
endpoint_dictionary_summary = rows("endpoint_dictionary_summary.csv")
morphology_context = rows("morphology_context_examples.csv")
morphology_context_summary = rows("morphology_context_model_summary.csv")
foundation_cohort = rows("foundation_model_cohort_audit.csv")
foundation_matched_screen = rows("foundation_model_matched_screen.csv")
foundation_summary = rows("foundation_model_matched_summary.csv")
foundation_pairwise = rows("foundation_model_pairwise_summary.csv")
foundation_target_comparison = rows("foundation_model_target_comparison.csv")
foundation_slide_set_summary = optional_rows("foundation_model_slide_set_summary.csv")
foundation_slide_difference_distribution = optional_rows("foundation_model_slide_count_difference_distribution.csv")
foundation_exact_slide_sensitivity = optional_rows("foundation_model_exact_common_slide_sensitivity_summary.csv")
foundation_family_summary = optional_rows("foundation_model_family_summary.csv")
foundation_cancer_summary = optional_rows("foundation_model_cancer_summary.csv")
foundation_normalized_breadth = rows("foundation_model_normalized_breadth_summary.csv")
foundation_evidence_maturity = rows("foundation_model_evidence_maturity_summary.csv")
titan_evidence_maturity = rows("titan_candidate_evidence_maturity_summary.csv")
foundation_endpoint_coverage = rows("foundation_model_endpoint_definition_coverage.csv")
foundation_endpoint_retention = rows("foundation_model_endpoint_cancer_retention.csv")
foundation_programme_retention = rows("foundation_model_programme_cancer_retention.csv")
foundation_provenance_summary = rows("foundation_model_provenance_stratified_summary.csv")
foundation_same_histology = rows("foundation_model_same_histology_sensitivity.csv")
foundation_biological_synthesis = rows("foundation_model_translational_biological_synthesis.csv")
foundation_concordance_summary = optional_rows("foundation_model_concordance_summary.csv")
foundation_discordant_targets = optional_rows("foundation_model_strongly_discordant_targets.csv")
foundation_tss_grouped = rows("foundation_model_tss_grouped_sensitivity.csv")
foundation_tss_summary = rows("foundation_model_tss_grouped_summary.csv")
foundation_tss_fold_audit = rows("foundation_model_tss_grouped_fold_audit.csv")
foundation_tss_fold_adequacy = rows("foundation_model_tss_grouped_fold_adequacy.csv")
foundation_tss_fold_adequacy_summary = rows("foundation_model_tss_grouped_fold_adequacy_summary.csv")
foundation_tss_fold_adequacy_by_class = rows("foundation_model_tss_grouped_fold_adequacy_by_deprecated_class.csv")
titan_site_fold_adequacy_summary = rows("site_grouped_fold_adequacy_summary.csv")
foundation_tss_crosstab = rows("foundation_model_consensus_tss_crosstab.csv")
foundation_robustness = rows("foundation_model_internal_robustness_classification.csv")
foundation_probe_summary = optional_rows("foundation_model_probe_ranking_summary.csv")
probe_by_type = {r["outcome_type"]: r for r in foundation_probe_summary}
foundation_component_audit = optional_rows("foundation_model_pls_component_audit.csv")
foundation_component_audit_by_key = {
    (r["foundation_model"], r["outcome_type"]): r
    for r in foundation_component_audit
}
foundation_variance_audit = optional_rows("foundation_model_feature_variance_audit.csv")
foundation_component_range = optional_rows("foundation_model_component_range_sensitivity_summary.csv")
foundation_component_winners = optional_rows("foundation_model_component_range_winner_sensitivity.csv")
foundation_binary_component20_summary = optional_rows(
    "foundation_model_binary_component_range_20_summary.csv"
)
foundation_binary_component20_targets = optional_rows(
    "foundation_model_binary_component_range_20_targets.csv"
)
foundation_binary_component_distribution = optional_rows(
    "foundation_model_binary_component_distribution.csv"
)
foundation_binary_component_features = optional_rows(
    "foundation_model_binary_component_feature_handling.csv"
)
_foundation_titan_prov_component20_rows = optional_rows(
    "foundation_model_TITAN_ProvGigaPath_binary_component_range.csv"
)
foundation_titan_prov_component20 = (
    _foundation_titan_prov_component20_rows[0]
    if _foundation_titan_prov_component20_rows else {}
)
foundation_binary_component20_by_model = {
    r["foundation_model"]: r for r in foundation_binary_component20_summary
}
if not foundation_binary_component20_by_model:
    foundation_binary_component20_by_model = {
        model: {
            "maximum_absolute_auroc_delta": "",
            "expanded_outer_fits_at_ceiling": "",
        }
        for model in ("TITAN", "GigaSSL", "ProvGigaPath")
    }
if not foundation_titan_prov_component20:
    foundation_titan_prov_component20 = {
        "tasks": "", "primary_spearman": "", "expanded_spearman": "",
        "primary_median_TITAN_minus_ProvGigaPath": "",
        "expanded_median_TITAN_minus_ProvGigaPath": "",
        "primary_TITAN_higher": "", "expanded_TITAN_higher": "",
        "primary_ProvGigaPath_higher": "", "expanded_ProvGigaPath_higher": "",
        "pairwise_leader_changed": "",
    }


def component_distribution_summary(model, grid):
    selected = [
        r for r in foundation_binary_component_distribution
        if r["foundation_model"] == model and r["component_grid"] == grid
    ]
    expanded = []
    for row in selected:
        expanded.extend([ival(row["selected_component"])] * ival(row["outer_fits"]))
    expanded.sort()
    if not expanded:
        return {"median": float("nan"), "q1": float("nan"),
                "q3": float("nan"), "top": "NA"}
    def empirical_quantile(probability):
        return expanded[round((len(expanded) - 1) * probability)]
    top = sorted(
        selected, key=lambda row: ival(row["outer_fits"]), reverse=True
    )[:3]
    return {
        "median": empirical_quantile(0.5),
        "q1": empirical_quantile(0.25),
        "q3": empirical_quantile(0.75),
        "top": ", ".join(
            f"{row['selected_component']} ({fnum(row['outer_fit_percent'], 1)}%)"
            for row in top
        ),
    }


foundation_binary_component_distribution_summary = {
    (model, grid): component_distribution_summary(model, grid)
    for model in ("TITAN", "GigaSSL", "ProvGigaPath")
    for grid in ("1-10", "1-20")
}
foundation_component_winner_summary = {}
for outcome in ("binary", "continuous"):
    z = [r for r in foundation_component_winners if r.get("outcome_type") == outcome]
    foundation_component_winner_summary[outcome] = {
        "targets": len(z),
        "retained": sum(r.get("winner10") == r.get("winner20") for r in z),
    }
foundation_fold_selection = optional_rows("foundation_model_fold_stability_selection.csv")
foundation_fold_summary = optional_rows("foundation_model_fold_stability_summary.csv")
foundation_crossing_stability = optional_rows("foundation_model_crossing_stability.csv")
foundation_consensus_stability = optional_rows("foundation_model_consensus_stability.csv")
foundation_threshold_stability = optional_rows("foundation_model_threshold_sensitivity.csv")
foundation_effect_rank_stability = optional_rows("foundation_model_effect_rank_stability.csv")
foundation_winner_stability = optional_rows("foundation_model_winner_stability.csv")
foundation_pairwise_repeat_stability = optional_rows("foundation_model_pairwise_repeat_stability.csv")
foundation_effect_partition_audit = rows("foundation_model_effect_partition_audit.csv")


def _empirical_quantile(values, probability):
    ordered = sorted(values)
    if not ordered:
        return float("nan")
    return ordered[round((len(ordered) - 1) * probability)]


foundation_crossing_stability_by_key = {}
for model in ("TITAN", "GigaSSL", "ProvGigaPath"):
    for outcome in ("continuous", "binary"):
        selected = [
            r for r in foundation_crossing_stability
            if r["foundation_model"] == model and r["outcome_type"] == outcome
        ]
        crossing_proportions = [float(r["crossing_proportion"]) for r in selected]
        effect_sds = [float(r["sd_effect"]) for r in selected]
        foundation_crossing_stability_by_key[(model, outcome)] = {
            "tasks": len(selected),
            "all_five": sum(value == 1.0 for value in crossing_proportions),
            "median_crossing_proportion": statistics.median(crossing_proportions),
            "median_effect_sd": statistics.median(effect_sds),
            "effect_sd_q1": _empirical_quantile(effect_sds, 0.25),
            "effect_sd_q3": _empirical_quantile(effect_sds, 0.75),
        }

foundation_consensus_stability_overall = {}
for outcome in ("continuous", "binary"):
    selected = [r for r in foundation_consensus_stability if r["outcome_type"] == outcome]
    agreement = [float(r["primary_consensus_agreement_proportion"]) for r in selected]
    foundation_consensus_stability_overall[outcome] = {
        "tasks": len(selected),
        "all_five": sum(value == 1.0 for value in agreement),
        "at_least_four": sum(value >= 0.8 for value in agreement),
        "median": statistics.median(agreement),
    }
analysis_chronology = reference_rows("analysis_chronology.csv")
model_inventory = reference_rows("model_inventory_by_representation_family.csv")
model_inventory_reconciliation = rows("fitted_model_inventory_reconciliation.csv")
software_access = reference_rows("software_access_licensing_matrix.csv")
translational_consensus = reference_rows("translational_consensus_target_audit.csv")
translational_consensus_family = reference_rows("translational_consensus_by_endpoint_family.csv")
translational_consensus_examples = reference_rows("translational_consensus_main_examples.csv")
titan_prov_paired = reference_rows("titan_provgigapath_paired_summary.csv")
foundation_exclusion_inventory = reference_rows("foundation_model_exclusion_inventory.csv")
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
foundation_summary_by_key = {
    (r["foundation_model"], r["outcome_type"]): r for r in foundation_summary
}
foundation_binary_auroc_by_model = {
    r["foundation_model"]: r for r in foundation_binary_auroc_summary
}
foundation_binary_operating_by_key = {
    (r["foundation_model"], r["rule"]): r
    for r in foundation_binary_operating_summary
}
foundation_binary_consensus_changed = sum(
    r["empirical_to_auroc_tuned_ba_consensus_changed"].upper() == "TRUE"
    for r in foundation_binary_estimand
)
foundation_binary_winner_changed = sum(
    r["auroc_winner_changed"].upper() == "TRUE"
    for r in foundation_binary_estimand
)
foundation_binary_consensus_counts = {
    field: Counter(r[field] for r in foundation_binary_estimand)
    for field in (
        "empirical_ba_consensus", "auroc_tuned_ba_consensus",
        "auroc_tuned_auroc_consensus",
    )
}
foundation_breadth_by_key = {
    (r["foundation_model"], r["outcome_type"]): r
    for r in foundation_normalized_breadth
}
foundation_maturity_by_key = {
    (r["foundation_model"], r["outcome_type"]): r
    for r in foundation_evidence_maturity
}
multiplicity_p_by_outcome = {
    r["outcome_type"]: r for r in multiplicity_p_assignment
}
multiplicity_denominator_by_outcome = {
    r["outcome_type"]: r for r in multiplicity_denominators
}
titan_maturity_by_outcome = {
    r["outcome_type"]: r for r in titan_evidence_maturity
}
foundation_provenance_by_key = {
    (r["foundation_model"], r["outcome_type"], r["measurement_class"]): r
    for r in foundation_provenance_summary
}
endpoint_measurement_class = {
    (r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"], r["source"]):
    r["measurement_class"]
    for r in endpoint_dictionary
}
endpoint_same_histology = {
    (r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"], r["source"]):
    r["same_histology_modality"].upper() == "TRUE"
    for r in endpoint_dictionary
}


def _target_definition_key(row):
    return (row["outcome_type"], row["family"], row["endpoint"], row["source"])


for row in foundation_target_comparison:
    endpoint_key = (
        row["outcome_type"], row["family"], row["tumor_type"],
        row["endpoint"], row["source"]
    )
    row["measurement_class"] = endpoint_measurement_class[endpoint_key]
    row["same_histology_modality"] = endpoint_same_histology[endpoint_key]

foundation_union_positive = [
    r for r in foundation_target_comparison if ival(r["supported_by_n"]) > 0
]
foundation_at_least_two = [
    r for r in foundation_target_comparison if ival(r["supported_by_n"]) >= 2
]
foundation_all_three = [
    r for r in foundation_target_comparison if ival(r["supported_by_n"]) == 3
]


def _atlas_count_summary(data):
    return {
        "tasks": len(data),
        "continuous": sum(r["outcome_type"] == "continuous" for r in data),
        "binary": sum(r["outcome_type"] == "binary" for r in data),
        "unique_definitions": len({_target_definition_key(r) for r in data}),
        "continuous_definitions": len({
            _target_definition_key(r) for r in data
            if r["outcome_type"] == "continuous"
        }),
        "binary_definitions": len({
            _target_definition_key(r) for r in data
            if r["outcome_type"] == "binary"
        }),
    }


foundation_union_counts = _atlas_count_summary(foundation_union_positive)
foundation_two_counts = _atlas_count_summary(foundation_at_least_two)
foundation_all_three_counts = _atlas_count_summary(foundation_all_three)

foundation_crossmodal_union = [
    r for r in foundation_union_positive if not r["same_histology_modality"]
]
foundation_leader_counts = Counter(
    r["best_foundation_model"] for r in foundation_crossmodal_union
)
foundation_leader_by_feature_class = defaultdict(Counter)
for row in foundation_crossmodal_union:
    feature_key = (row["outcome_type"], row["measurement_class"])
    foundation_leader_by_feature_class[feature_key][row["best_foundation_model"]] += 1

predictable_feature_classes = [
    ("Direct genomic alterations", "binary", "directly observed genomic alteration",
     "GTF2I, BRAF, IDH1, TP53, ATRX, CIC, FGFR3, APC, PTEN and called fusions"),
    ("Composite genomic-context status", "binary", "composite genomic-context score",
     "MSI, genome doubling and TP53, RTK-RAS, HIPPO, WNT and NOTCH pathway status"),
    ("Sequencing-derived burdens", "continuous", "sequencing-derived continuous burden",
     "MANTIS, aneuploidy, TCR diversity and SNV neoantigens"),
    ("Transcriptomic signatures", "continuous", "transcriptomic signature",
     "TGF-beta, IFN-gamma, proliferation, wound healing and Th1, Th2 and Th17 programmes"),
    ("Inferred immune-cell fractions", "continuous", "computationally inferred immune-cell fraction",
     "leukocyte, naive B-cell, M2-macrophage and regulatory T-cell fractions"),
    ("Continuous genomic-context scores", "continuous", "composite genomic-context score",
     "aneuploidy, fraction altered, homologous-recombination defects, segment count and stromal fraction"),
    ("Same-H&E TIL fraction", "continuous", "pathology-associated quantity",
     "TIL Regional Fraction"),
]


def _feature_class_summary(outcome_type, measurement_class):
    eligible = [
        r for r in foundation_target_comparison
        if r["outcome_type"] == outcome_type
        and r["measurement_class"] == measurement_class
    ]
    union = [r for r in eligible if ival(r["supported_by_n"]) > 0]
    all_three = [r for r in eligible if ival(r["supported_by_n"]) == 3]
    return {
        "eligible": len(eligible),
        "union": len(union),
        "all_three": len(all_three),
        "unique_union": len({_target_definition_key(r) for r in union}),
        "unique_all_three": len({_target_definition_key(r) for r in all_three}),
    }


predictable_feature_summary = {
    (outcome, measurement_class): _feature_class_summary(outcome, measurement_class)
    for _, outcome, measurement_class, _ in predictable_feature_classes
}
coad_multifoundation_by_key = {
    (r["patient_id"], r["foundation_model"], r["endpoint"]): r
    for r in coad_multifoundation_predictions
}
foundation_same_histology_by_model = {
    r["foundation_model"]: r for r in foundation_same_histology
}
foundation_cohort_by_model = {r["foundation_model"]: r for r in foundation_cohort}
foundation_matched_by_key = {
    (r["foundation_model"], r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"]): r
    for r in foundation_matched_screen
}


def matched_binary_metric(model, tumour, family, endpoint, field):
    return fnum(
        foundation_matched_by_key[(model, "binary", family, tumour, endpoint)][field]
    )
foundation_pairwise_by_key = {
    (r["comparison"], r["outcome_type"]): r for r in foundation_pairwise
}
titan_prov_paired_by_outcome = {r["outcome_type"]: r for r in titan_prov_paired}
foundation_slide_audit = foundation_slide_set_summary[0] if foundation_slide_set_summary else {}
foundation_exact_by_key = {
    (r["foundation_model"], r["outcome_type"]): r
    for r in foundation_exact_slide_sensitivity
}
foundation_fold_summary_by_key = {
    (r["foundation_model"], r["outcome_type"]): r for r in foundation_fold_summary
}
foundation_tss_summary_by_key = {
    (r["foundation_model"], r["outcome_type"]): r
    for r in foundation_tss_summary
}
foundation_tss_adequacy_by_outcome = {
    r["outcome_type"]: r for r in foundation_tss_fold_adequacy_summary
}
foundation_tss_adequacy_by_key = {
    (r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"]): r
    for r in foundation_tss_fold_adequacy
}
titan_site_adequacy_by_outcome = {
    r["outcome_type"]: r for r in titan_site_fold_adequacy_summary
}
foundation_tss_adequacy_class_by_key = {
    r["deprecated_r1_r4_class"]: r
    for r in foundation_tss_fold_adequacy_by_class
}
foundation_tss_by_key = {
    (r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"],
     r["foundation_model"]): r for r in foundation_tss_grouped
}
foundation_tss_feasible_rows = [
    r for r in foundation_tss_grouped if r.get("feasible") == "TRUE"
]
foundation_tss_infeasible_rows = [
    r for r in foundation_tss_grouped if r.get("feasible") != "TRUE"
]
foundation_tss_infeasible_tasks = sorted({
    (r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"])
    for r in foundation_tss_infeasible_rows
})
foundation_tss_code_min = min(ival(r["n_codes"]) for r in foundation_tss_fold_adequacy)
foundation_tss_code_max = max(ival(r["n_codes"]) for r in foundation_tss_fold_adequacy)
foundation_robustness_class_counts = Counter(
    r["internal_robustness_class"] for r in foundation_robustness
)
foundation_tss_consensus_counts = Counter(
    (r["outcome_type"], r["primary_consensus_class"], r["tss_retention_class"])
    for r in foundation_robustness
)
foundation_crossing_stability_rows_by_key = defaultdict(list)
for r in foundation_crossing_stability:
    foundation_crossing_stability_rows_by_key[(r["foundation_model"], r["outcome_type"])].append(r)
foundation_crossing_task_map = {
    (r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"], r["foundation_model"]): r
    for r in foundation_crossing_stability
}
foundation_effect_partition_map = {
    (r.get("outcome_type"), r.get("family"), r.get("tumor_type"),
     r.get("endpoint"), r.get("foundation_model")): r
    for r in foundation_effect_partition_audit
}
foundation_consensus_by_key = defaultdict(list)
for r in foundation_consensus_stability:
    foundation_consensus_by_key[(r["outcome_type"], r["primary_consensus_class"])].append(r)
foundation_common_n = ival(
    foundation_cohort_by_model.get("TITAN", {}).get("common_three_model_patients")
)
supported_c = [r for r in continuous if r["tier"] in ("A", "B")]
supported_b = [r for r in binary if r["tier"] in ("A", "B")]
titan_candidate_total = len(supported_c) + len(supported_b)

def foundation_crossings(model, outcome):
    row = foundation_summary_by_key.get((model, outcome), {})
    return ival(
        row.get("screening_positive")
        or row.get("screen_statistic_ge_tier_B")
    )

def foundation_breadth(model, outcome, field):
    return float(foundation_breadth_by_key[(model, outcome)][field])

def foundation_breadth_label(model, outcome):
    r = foundation_breadth_by_key[(model, outcome)]
    return (
        f"{ival(r['task_crossings']):,}/{ival(r['eligible_tasks']):,} "
        f"({fnum(r['task_crossing_percent'], 1)}%)"
    )

def foundation_definition_label(model, outcome):
    r = foundation_breadth_by_key[(model, outcome)]
    return (
        f"{ival(r['endpoint_definitions_crossing']):,}/{ival(r['eligible_endpoint_definitions']):,} "
        f"({fnum(r['endpoint_definition_crossing_percent'], 1)}%)"
    )

def foundation_standard_label(model, outcome):
    r = foundation_maturity_by_key[(model, outcome)]
    return (
        f"{ival(r['standard_evidence_crossings']):,}/"
        f"{ival(r['standard_evidence_eligible_tasks']):,} "
        f"({fnum(r['standard_evidence_crossing_percent_of_standard_eligible'], 1)}%)"
    )

def foundation_standard_of_crossings(model, outcome):
    r = foundation_maturity_by_key[(model, outcome)]
    return (
        f"{ival(r['standard_evidence_crossings']):,}/"
        f"{ival(r['inclusive_crossings']):,}"
    )

def binary_operating_value(model, rule, field):
    return foundation_binary_operating_by_key[(model, rule)][field]

def provenance_crossing_label(model, outcome, measurement_class):
    r = foundation_provenance_by_key[(model, outcome, measurement_class)]
    return (
        f"{ival(r['effect_threshold_crossings'])}/{ival(r['eligible_tasks'])} "
        f"({fnum(r['crossing_percent'], 1)}%)"
    )

def same_histology_exclusion_label(model, scope="continuous"):
    r = foundation_same_histology_by_model[model]
    if scope == "continuous":
        return (
            f"{ival(r['all_continuous_crossings'])}/{ival(r['all_continuous_tasks'])} to "
            f"{ival(r['cross_modal_continuous_crossings'])}/{ival(r['cross_modal_continuous_tasks'])}"
        )
    return (
        f"{ival(r['all_matched_crossings'])}/{ival(r['all_matched_tasks'])} to "
        f"{ival(r['matched_crossings_excluding_same_histology'])}/"
        f"{ival(r['matched_tasks_excluding_same_histology'])}"
    )

def cross_modal_continuous_label(model):
    r = foundation_same_histology_by_model[model]
    return (
        f"{ival(r['cross_modal_continuous_crossings']):,}/"
        f"{ival(r['cross_modal_continuous_tasks']):,} "
        f"({fnum(r['cross_modal_continuous_crossing_percent'], 1)}%)"
    )

def cross_modal_larger_sample_label(model):
    maturity = foundation_maturity_by_key[(model, "continuous")]
    same_histology = foundation_same_histology_by_model[model]
    crossings = (
        ival(maturity["standard_evidence_crossings"])
        - ival(same_histology["same_histology_crossings"])
    )
    eligible = (
        ival(maturity["standard_evidence_eligible_tasks"])
        - ival(same_histology["matched_same_histology_tasks"])
    )
    return f"{crossings:,}/{eligible:,} ({100 * crossings / eligible:.1f}%)"

def foundation_tss_retention(model, outcome):
    row = foundation_tss_summary_by_key.get((model, outcome), {})
    return (ival(row.get("retained_primary_crossings")),
            ival(row.get("primary_crossings")))

def foundation_tss_retention_percent(model, outcome):
    row = foundation_tss_summary_by_key.get((model, outcome), {})
    return float(row.get("retention_percent") or 0)

def foundation_tss_grouped_minus_matched(model, outcome):
    row = foundation_tss_summary_by_key.get((model, outcome), {})
    return float(row.get("median_grouped_minus_matched_effect") or 0)

def stable_primary_crossings(model, outcome):
    values = [r for r in foundation_crossing_stability_rows_by_key[(model, outcome)]
              if r.get("primary_crossing") == "TRUE"]
    return sum(float(r.get("crossing_proportion") or 0) == 1.0 for r in values), len(values)

def consensus_class_stability(outcome, classes):
    values = []
    for cls in classes:
        values.extend(foundation_consensus_by_key[(outcome, cls)])
    return sum(float(r.get("primary_consensus_agreement_proportion") or 0) == 1.0
               for r in values), len(values)

def winner_stability(outcome):
    values = [r for r in foundation_winner_stability if r.get("outcome_type") == outcome]
    return {
        "tasks": len(values),
        "all_five": sum(float(r.get("primary_winner_repeat_proportion") or 0) == 1.0 for r in values),
        "majority": sum(float(r.get("primary_winner_repeat_proportion") or 0) >= 0.6 for r in values),
        "median": statistics.median(float(r.get("primary_winner_repeat_proportion") or 0) for r in values),
    }

def threshold_mean_crossings(model, outcome, threshold):
    values = [r for r in foundation_threshold_stability
              if r.get("foundation_model") == model
              and r.get("outcome_type") == outcome
              and int(r.get("stability_repeat") or 0) == 1
              and abs(float(r.get("threshold") or -99) - threshold) < 1e-9]
    return float(values[0]["mean_crossings"]) if values else float("nan")

inventory_by_representation = defaultdict(int)
inventory_by_representation_outcome = defaultdict(int)
for inventory_row in model_inventory:
    count = ival(inventory_row.get("fitted_models"))
    inventory_by_representation[inventory_row.get("foundation_model")] += count
    inventory_by_representation_outcome[(
        inventory_row.get("foundation_model"), inventory_row.get("outcome_type")
    )] += count
registry_object_total = sum(inventory_by_representation.values())
inventory_reconciliation_by_key = {
    (r.get("foundation_model"), r.get("outcome_type")): r
    for r in model_inventory_reconciliation
}

def inventory_reconciliation_value(model, outcome, field):
    return ival(inventory_reconciliation_by_key[(model, outcome)].get(field))
binary_standard = [
    r for r in binary_reliability
    if r.get("model_evidence_tier") == "standard_internal_evidence"
]
binary_limited_reliability = [
    r for r in binary_reliability
    if r.get("model_evidence_tier") == "exploratory_limited_evidence"
]
continuous_standard = [r for r in continuous_reliability if ival(r.get("n")) >= 100]
continuous_limited_reliability = [r for r in continuous_reliability if ival(r.get("n")) < 100]
continuous_evidence_by_category = {r.get("evidence_category"): r for r in continuous_evidence_summary}
continuous_association_by_metric = {r.get("metric"): r for r in continuous_reliability_associations}
binary_reliability_by_key = {
    (r.get("family"), r.get("tumor_type"), r.get("endpoint")): r
    for r in binary_reliability
}
low_prevalence_mutation_fusion = [
    r for r in binary_reliability
    if r.get("family") in ("driver_mutation", "fusion")
    and float(r.get("observed_tcga_prevalence") or 1) < 0.20
]
binary_sensitivity_20 = next(
    (r for r in binary_class_sensitivity if r.get("minimum_per_class") == "20"), {}
)
binary_sensitivity_50 = next(
    (r for r in binary_class_sensitivity if r.get("minimum_per_class") == "50"), {}
)
coad_supported_c = [r for r in supported_c if r["tumor_type"] == "COAD"]
coad_supported_b = [r for r in supported_b if r["tumor_type"] == "COAD"]
global_supported_c = [r for r in supported_c if float(r["q_value_global"]) < 0.05]
global_supported_b = [r for r in supported_b if float(r["q_value_global"]) < 0.05]
global_mutation_b = [r for r in global_supported_b if r["family"] == "driver_mutation"]
combined_multiplicity = next(
    (r for r in multiplicity_summary if r.get("outcome_type") == "combined"), {}
)
zero_999 = [
    r for r in permutation_uncertainty
    if r.get("permutations") == "999"
    and r.get("permutation_exceedances") == "0"
    and r.get("permutation_stopped_early") == "FALSE"
]
zero_999_upper = max(
    (float(r["p_mc_upper_95"]) for r in zero_999 if r.get("p_mc_upper_95")),
    default=float("nan"),
)
targeted_zero = [r for r in targeted_permutation if r.get("zero_exceedances") == "TRUE"]
targeted_p_min = min(
    (float(r["refined_p_9999"]) for r in targeted_permutation),
    default=float("nan"),
)
targeted_p_max = max(
    (float(r["refined_p_9999"]) for r in targeted_permutation),
    default=float("nan"),
)
targeted_p_summary = (
    f"all {fnum(targeted_p_min, 4)}"
    if targeted_permutation and abs(targeted_p_max - targeted_p_min) < 1e-12
    else f"{fnum(targeted_p_min, 4)}–{fnum(targeted_p_max, 4)}"
)
top_c = sorted(supported_c, key=lambda r: float(r["q2"]), reverse=True)
top_b = sorted(supported_b, key=lambda r: float(r["balanced_accuracy"]), reverse=True)
global_abstract_text = (
    f'{len(global_supported_c)} continuous and {len(global_mutation_b)} cancer–mutation '
    f'pairs passed the stricter across-cancer correction'
)

if highlighted:
    highlighted_continuous = [
        r for r in highlighted if r.get("outcome_type") == "continuous"
    ]
    abstract_continuous = max(
        highlighted_continuous,
        key=lambda r: float(r.get("q2") or "-inf"),
        default=None,
    )
    abstract_binary = next(
        (r for r in highlighted if r.get("outcome_type") == "binary"), None
    )
else:
    abstract_continuous = abstract_binary = None

if abstract_continuous and abstract_binary:
    abstract_metric_text = (
        f'{abstract_continuous["tumor_type"]}–{abstract_continuous["endpoint"]} '
        f'(five-repeat mean Q² {fnum(abstract_continuous.get("q2"))}, selection-conditioned 95% patient-resampling interval '
        f'{fnum(abstract_continuous.get("q2_ci_low"))}–{fnum(abstract_continuous.get("q2_ci_high"))}; RMSE '
        f'{fnum(abstract_continuous.get("rmse"))}, Spearman '
        f'{fnum(abstract_continuous.get("spearman"))}) and '
        f'{abstract_binary["tumor_type"]}–{abstract_binary["endpoint"]} '
        f'(five-repeat mean sensitivity {fnum(abstract_binary.get("sensitivity"))}, specificity '
        f'{fnum(abstract_binary.get("specificity"))}, balanced accuracy '
        f'{fnum(abstract_binary.get("balanced_accuracy"))}, selection-conditioned 95% patient-resampling interval '
        f'{fnum(abstract_binary.get("balanced_accuracy_ci_low"))}–{fnum(abstract_binary.get("balanced_accuracy_ci_high"))}; AUROC '
        f'{fnum(abstract_binary.get("auc"))}, PR-AUC {fnum(abstract_binary.get("pr_auc"))})'
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
pathology_qc = pathology_qc_mentions[0] if pathology_qc_mentions else {}
maximum_slide_patient = pathology_qc_max[0] if pathology_qc_max else {}
no_residual_patient_summary = (
    pathology_qc_no_residual_summary[0] if pathology_qc_no_residual_summary else {}
)
no_residual_sensitivity_by_type = {
    r.get("outcome_type"): r for r in no_residual_exclusion_summary
}
no_residual_sensitivity_total = sum(
    ival(r.get("models")) for r in no_residual_exclusion_summary
)
no_residual_threshold_retained_total = sum(
    ival(r.get("threshold_retained")) for r in no_residual_exclusion_summary
)
no_residual_highlighted_max_abs_delta = max(
    (abs(float(r.get("delta_exclusion_minus_original")))
     for r in no_residual_exclusion_highlighted),
    default=float("nan"),
)
n_mc3_profiled = sum(ival(r.get("matched_profiled_patients")) for r in mutation_coverage)
n_mc3_missing = sum(ival(r.get("embedding_patients_without_mc3_profile")) for r in mutation_coverage)
n_mutation_eligible = sum(r.get("eligibility") == "eligible" for r in mutation_eligibility)
n_mutation_ineligible = len(mutation_eligibility) - n_mutation_eligible
participant_overall = next(
    (r for r in participant_characteristics if r.get("tumor_type") == "Overall"),
    {},
)
subgroup_high_volume_models = {
    (r.get("outcome_type"), r.get("family"), r.get("tumor_type"), r.get("endpoint"))
    for r in subgroup_performance if r.get("high_volume") == "TRUE"
}
subgroup_estimable_rows = [r for r in subgroup_performance if r.get("denominator_adequate") == "TRUE"]
subgroup_model_groups = {}
for r in subgroup_estimable_rows:
    key = (r.get("outcome_type"), r.get("family"), r.get("tumor_type"),
           r.get("endpoint"), r.get("subgroup_variable"))
    subgroup_model_groups.setdefault(key, set()).add(r.get("subgroup"))
subgroup_two_group_models = {
    "continuous_sex": sum(k[0] == "continuous" and k[4] == "Recorded sex" and len(v) >= 2
                          for k, v in subgroup_model_groups.items()),
    "continuous_race": sum(k[0] == "continuous" and k[4] == "Broad race" and len(v) >= 2
                           for k, v in subgroup_model_groups.items()),
    "binary_sex": sum(k[0] == "binary" and k[4] == "Recorded sex" and len(v) >= 2
                      for k, v in subgroup_model_groups.items()),
    "binary_race": sum(k[0] == "binary" and k[4] == "Broad race" and len(v) >= 2
                       for k, v in subgroup_model_groups.items()),
}
subgroup_contrast = {(r.get("contrast"), r.get("outcome_type")): r for r in subgroup_contrasts}
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

measurement_class_order = (
    "directly observed genomic alteration",
    "sequencing-derived continuous burden",
    "computationally inferred immune-cell fraction",
    "transcriptomic signature",
    "pathology-associated quantity",
    "composite genomic-context score",
)
endpoint_class_summary = []
for measurement_class in measurement_class_order:
    class_rows = [
        r for r in endpoint_dictionary
        if r.get("measurement_class") == measurement_class
    ]
    endpoint_class_summary.append((
        measurement_class,
        len(class_rows),
        len({
            (r.get("outcome_type"), r.get("family"), r.get("endpoint"))
            for r in class_rows
        }),
        sum(r.get("same_histology_modality") == "TRUE" for r in class_rows),
    ))

definition_group_summary = []
for group in sorted({r.get("definition_group") for r in endpoint_dictionary}):
    group_tests = [r for r in endpoint_dictionary if r.get("definition_group") == group]
    representative = group_tests[0]
    definition_group_summary.append((
        group,
        representative.get("measurement_class"),
        len(group_tests),
        len({
            (r.get("outcome_type"), r.get("family"), r.get("endpoint"))
            for r in group_tests
        }),
        representative.get("source_modality"),
        representative.get("direct_vs_inferred"),
        representative.get("derivation_algorithm"),
        representative.get("original_scale"),
        representative.get("equivalence_caveat"),
    ))
endpoint_class_result_text = "; ".join(
    f"{tests:,} {measurement_class}"
    for measurement_class, tests, _, _ in endpoint_class_summary
)

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
    return {"A": "within-cancer screening tier A",
            "B": "within-cancer screening tier B",
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


binary_learning_medians = {}
for fraction in ("0.5", "0.50", "0.75", "1", "1.0", "1.00"):
    matching = [r for r in binary_learning if r.get("training_fraction") == fraction]
    if matching:
        binary_learning_medians[float(fraction)] = {
            "balanced_accuracy": median(r.get("balanced_accuracy_mean") for r in matching),
            "auc": median(r.get("auc_mean") for r in matching),
            "pr_auc": median(r.get("pr_auc_mean") for r in matching),
        }
binary_learning_50 = binary_learning_medians.get(0.5, {})
binary_learning_75 = binary_learning_medians.get(0.75, {})
binary_learning_100 = binary_learning_medians.get(1.0, {})
binary_min_outer_positive = min(
    (ival(r.get("minimum_outer_test_positive")) for r in binary_reliability),
    default=0,
)
binary_min_outer_negative = min(
    (ival(r.get("minimum_outer_test_negative")) for r in binary_reliability),
    default=0,
)
limited_min_inner_training_positive = min(
    (ival(r.get("minimum_inner_training_positive")) for r in binary_limited_reliability),
    default=0,
)
limited_min_inner_training_negative = min(
    (ival(r.get("minimum_inner_training_negative")) for r in binary_limited_reliability),
    default=0,
)
limited_min_inner_validation_positive = min(
    (ival(r.get("minimum_inner_validation_positive")) for r in binary_limited_reliability),
    default=0,
)
limited_min_inner_validation_negative = min(
    (ival(r.get("minimum_inner_validation_negative")) for r in binary_limited_reliability),
    default=0,
)


site_deltas = [r["delta"] for r in site_c + site_b if r.get("feasible") == "TRUE" and r.get("delta")]
pool_deltas = [r["delta_first_minus_mean"] for r in pool_c + pool_b if r.get("delta_first_minus_mean")]
median_pool_by_type = {r.get("outcome_type"): r for r in median_pool_summary}
heterogeneity_by_model = {r.get("foundation_model"): r for r in slide_heterogeneity}
linkage_by_source = {r.get("source"): r for r in molecular_slide_linkage}
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
site_control_by_type = {r.get("outcome_type"): r for r in site_partition_summary}
site_control_apc = {
    (r.get("tumor_type"), r.get("endpoint")): r for r in site_partition_controls
    if r.get("outcome_type") == "binary" and r.get("endpoint") == "APC"
}
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
site_grouped_by_key = {
    ("continuous", r.get("tumor_type"), r.get("endpoint")): r for r in site_c
}
site_grouped_by_key.update({
    ("binary", r.get("tumor_type"), r.get("endpoint")): r for r in site_b
})
coad_apc_site = site_grouped_by_key.get(("binary", "COAD", "APC"), {})
read_apc_site = site_grouped_by_key.get(("binary", "READ", "APC"), {})
site_predictability_eligible = [
    r for r in site_predictability
    if r.get("eligible") == "TRUE" and not r.get("error")
]
site_predictability_ineligible = [
    r for r in site_predictability if r.get("eligible") != "TRUE"
]
site_predictability_ranked = sorted(
    site_predictability_eligible,
    key=lambda r: float(r.get("normalized_macro_balanced_accuracy") or -1),
    reverse=True,
)
ridge_better = [r for r in ridge_comparison if r.get("selected_method") == "ridge"]
pls_better = [r for r in ridge_comparison if r.get("selected_method") == "PLS"]
baseline_uncertain = [
    r for r in ridge_comparison if r.get("selected_method") == "uncertain"
]
binary_baseline_summary = next(
    (r for r in ridge_summary if r.get("outcome_type") == "binary"), {}
)
continuous_baseline_summary = next(
    (r for r in ridge_summary if r.get("outcome_type") == "continuous"), {}
)
binary_secondary_ridge = [
    r for r in ridge_comparison
    if r.get("outcome_type") == "binary" and float(r.get("delta_secondary_ci_low")) > 0
]
binary_secondary_pls = [
    r for r in ridge_comparison
    if r.get("outcome_type") == "binary" and float(r.get("delta_secondary_ci_high")) < 0
]
binary_secondary_uncertain = [
    r for r in ridge_comparison
    if r.get("outcome_type") == "binary"
    and not (float(r.get("delta_secondary_ci_low")) > 0
             or float(r.get("delta_secondary_ci_high")) < 0)
]
continuous_secondary_ridge = [
    r for r in ridge_comparison
    if r.get("outcome_type") == "continuous"
    and float(r.get("delta_secondary_ci_low")) > 0
]
continuous_secondary_pls = [
    r for r in ridge_comparison
    if r.get("outcome_type") == "continuous"
    and float(r.get("delta_secondary_ci_high")) < 0
]
continuous_secondary_uncertain = [
    r for r in ridge_comparison
    if r.get("outcome_type") == "continuous"
    and not (float(r.get("delta_secondary_ci_low")) > 0
             or float(r.get("delta_secondary_ci_high")) < 0)
]
ridge_binary = [r for r in ridge_comparison if r.get("outcome_type") == "binary"]
ridge_continuous = [
    r for r in ridge_comparison if r.get("outcome_type") == "continuous"
]
binary_decision_summary_by_key = {
    (r.get("layer"), r.get("foundation_model"), r.get("subset")): r
    for r in binary_decision_summary
}
binary_decision_all = [
    r for r in binary_decision_summary if r.get("subset") == "all eligible"
]
titan_decision_all = binary_decision_summary_by_key.get(
    ("TITAN permutation/FDR screen", "TITAN", "all eligible"), {}
)
titan_decision_rows = [
    r for r in binary_decision_rule
    if r.get("layer") == "TITAN permutation/FDR screen"
]
titan_optimized_gains = [
    r for r in titan_decision_rows
    if r.get("recomputed_primary_crossing") == "FALSE"
    and r.get("optimized_crossing") == "TRUE"
]
titan_optimized_gains_limited = sum(
    min(ival(r.get("positive")), ival(r.get("negative"))) < 50
    for r in titan_optimized_gains
)
titan_optimized_crossing_limited = sum(
    min(ival(r.get("positive")), ival(r.get("negative"))) < 50
    for r in titan_decision_rows if r.get("optimized_crossing") == "TRUE"
)
titan_empirical_crossing_limited = sum(
    min(ival(r.get("positive")), ival(r.get("negative"))) < 50
    for r in titan_decision_rows
    if r.get("recomputed_primary_crossing") == "TRUE"
)

def matched_decision_count(model, field):
    return ival(binary_decision_summary_by_key.get(
        ("matched three-representation atlas", model, "all eligible"), {}
    ).get(field))
binary_decision_union_changes = sorted(
    binary_decision_changes,
    key=lambda r: max(
        abs(float(r.get("equal_prior_delta_ba") or 0)),
        abs(float(r.get("optimized_delta_ba") or 0)),
    ),
    reverse=True,
)
ridge_screen_positive = [
    r for r in ridge_comparison if r.get("screen_tier") in {"A", "B"}
]
binary_primary_ridge_labels = " and ".join(
    f'{r.get("tumor_type")}–{r.get("endpoint")}'
    for r in ridge_better if r.get("outcome_type") == "binary"
)
continuous_primary_ridge_labels = ", ".join(
    f'{r.get("tumor_type")}–{r.get("endpoint")}'
    for r in ridge_better if r.get("outcome_type") == "continuous"
)


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


def benchmark_family_label(value):
    return {
        "driver_mutation": "mut.",
        "microsatellite_instability_sensitivity": "MSI",
        "oncogenic_pathway": "pathway",
        "thorsson": "immune",
    }.get(value, value)


def benchmark_type_label(value):
    return {"binary": "bin.", "continuous": "cont."}.get(value, value)


def benchmark_metric_label(value):
    return {
        "AUROC (threshold-independent)": "AUROC",
        "balanced accuracy (inner-CV thresholds for both)": "BA",
        "Spearman correlation": "Spearman",
        "Q2": "Q²",
    }.get(value, value)


def benchmark_interpretation(value):
    return "uncertain" if "difference uncertain" in value else value


previously_reported_not_supported = selected_prior_records([
    ("BRCA", "TP53", "Kather2020"),
    ("UCEC", "TP53", "Loeffler2022"),
    ("LIHC", "CTNNB1", "Kather2020"),
    ("PAAD", "KRAS", "Kather2020"),
])


doc = setup(Document(), "Patient-level pathology foundation-model benchmark")
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
    ("Alessia Vignoli", "9,10"),
    ("Leonardo Tenori", "9,10"),
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
p.add_run("Department of Surgery, School of Clinical Medicine, Faculty of Health Sciences, University of the Witwatersrand, Johannesburg, Gauteng, South Africa")
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
p.add_run("9 ").bold = True
p.add_run('Department of Chemistry "Ugo Schiff", University of Florence, Sesto Fiorentino, Italy')
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("10 ").bold = True
p.add_run("Magnetic Resonance Center (CERM), University of Florence, Sesto Fiorentino, Italy")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("* These authors contributed equally.").italic = True
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("† Corresponding author: Stefano Cacciatore (stefano.cacciatore@icgeb.org).").italic = True
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("Author emails: aamilahismail@gmail.com; moussa.kassim@icgeb.org; dalia.ahmed@icgeb.org; dupe.ojo@icgeb.org; vignoli@cerm.unifi.it; tenori@cerm.unifi.it; stefano.cacciatore@icgeb.org")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("Research article: Molecular Pathology | Journal of Translational Medicine")

# Keep the complete author and affiliation block together on the title page.
for front_index, front_paragraph in enumerate(doc.paragraphs[1:16], start=1):
    front_paragraph.paragraph_format.space_before = Pt(0)
    front_paragraph.paragraph_format.space_after = Pt(0)
    front_paragraph.paragraph_format.line_spacing = 1.0
    front_size = Pt(9.5 if front_index == 1 else 8.5)
    for front_run in front_paragraph.runs:
        front_run.font.size = front_size

doc.add_heading("Abstract", level=1)
add_labelled(
    doc,
    "Background.",
    "Routine haematoxylin and eosin (H&E) slides contain morphological correlates of tumour genotype and microenvironment, but which signals persist across pathology foundation-model pipelines remains unclear. We compared three released whole-slide representations to map cancer-specific predictability of mutations, fusions, genomic instability, RNA-derived pathway activity and derived immune phenotypes."
)
add_labelled(
    doc,
    "Methods.",
    f"We analysed {foundation_common_n:,} patients across 30 The Cancer Genome Atlas (TCGA) cancer types and 3,389 cancer-endpoint pairs with TITAN, Giga-SSL and Prov-GigaPath representations. We mean-pooled multiple slides within patients and used identical outcome subsets and nested patient-level folds with a common 1-to-20-component partial least-squares regression and linear discriminant classification pipeline. Cross-validated Q² and area under the receiver operating characteristic curve (AUROC) were primary metrics; Q² at least 0.20 and AUROC at least 0.60 summarized catalogue breadth. Alternative partitions and grouping by TCGA tissue-source-site code assessed stability. A supporting {n_patients:,}-patient TITAN screen used permutation and false-discovery-rate control."
)
add_labelled(
    doc,
    "Results.",
    f"Excluding 11 same-H&E tasks, TITAN, Giga-SSL and Prov-GigaPath crossed the Q² threshold in 633, 351 and 430 of 2,952 cross-modal continuous tasks. They crossed the AUROC threshold in {foundation_crossings('TITAN', 'binary')}, {foundation_crossings('GigaSSL', 'binary')} and {foundation_crossings('ProvGigaPath', 'binary')} of 426 binary tasks, including 137, 92 and 98 of 243 directly observed genomic-alteration tasks. Shared signals included THYM-GTF2I mutation (AUROC 0.904, 0.884 and 0.893), strict COAD microsatellite instability (0.940, 0.851 and 0.857), UCEC fusion status (0.859, 0.661 and 0.705) and TGCT TGF-beta response (Q² 0.662, 0.647 and 0.601), ordered as TITAN, Giga-SSL and Prov-GigaPath. No pipeline led every endpoint. In the supporting TITAN screen, grouping by tissue-source-site code moved {ival(site_combined.get('below_threshold_models'))} of {ival(site_combined.get('screen_positive_models'))} candidates below their original threshold and reduced COAD-APC and READ-APC performance towards chance."
)
add_labelled(
    doc,
    "Conclusions.",
    "Histology contained reproducible cross-pipeline signals for mutations, fusions, microsatellite instability, genomic context and derived inflammatory phenotypes. TITAN provided the broadest task-level coverage under this probe, while some endpoints favoured another representation. The atlas and PathoFMPred prioritize candidates for independent validation, but internal TCGA estimates and cohort-structure sensitivity preclude clinical use."
)
doc.add_paragraph("Keywords: computational pathology; whole-slide imaging; foundation model; mutation; inflammation; microsatellite instability; gene fusion; aneuploidy; partial least squares; linear discriminant analysis")

doc.add_heading("Background", level=1)
doc.add_paragraph("Digital pathology converts routine haematoxylin-and-eosin whole-slide images into computational data. Pathology foundation models are neural networks pretrained on large and diverse slide collections so that one fixed model can encode each slide as a reusable numerical representation for many downstream tasks. This approach differs from a task-specific convolutional neural network trained separately for one mutation or cancer. The resulting representation can support a compact downstream model even when labelled molecular data are limited. Routine sections also reflect phenotypic consequences of tumour genotype and the immune microenvironment. Coudray and colleagues established mutation prediction from lung histology [1]. Subsequent work predicted microsatellite instability, including externally validated colorectal models [2,3]; extended mutation and multi-omic screening across TCGA cancers [4,5,8,11,13]; inferred RNA expression [6,12]; identified institution-associated histology bias [7]; detected gene fusions [9,10]; estimated homologous-recombination deficiency [14]; and characterised tumour-microenvironment phenotypes [15]. Collectively, these studies establish biological plausibility while also showing that performance depends on endpoint, disease, cohort and validation design.")
doc.add_paragraph("Prior studies established that H&E images can predict mutations, microsatellite instability and other molecular phenotypes, but they used different cohorts, image encoders, endpoints and validation rules. Fu et al. analysed 17,355 slides across 28 cancers [4], Kather et al. applied one workflow to more than 5,000 patients across 14 cancers [5], Saldanha et al. externally tested mutation models across seven matched TCGA and CPTAC cancers [11], and Arslan et al. trained 12,093 models for 4,031 genomic, transcriptomic, proteomic and clinical biomarkers in 8,890 TCGA patients across 32 cancers [13]. These studies provide the biological and methodological context for our matched comparison of released representation pipelines.")
doc.add_paragraph("The narrower unresolved gap is a reproducible multi-representation atlas that maps, for the same patients and endpoints, how molecular and derived immune-feature associations compare across released pathology embedding pipelines under one transparent downstream analysis. We deterministically aggregated slides before outcome matching, validated models at patient level and preserved tested-negative and sample-size-ineligible results. We also created PathoFMPred as a reproducible analysis interface and model registry. Its downloadable Giga-SSL and Prov-GigaPath collections cover a defined subset of atlas tasks, while its TITAN collection remains private pending redistribution permission. We therefore do not present the software as a complete operationalization of the atlas. The matched representation comparison, patient-level analysis and transparent reporting define the study's principal contributions.")
doc.add_paragraph("Foundation models learn general visual representations from large image collections before a specific downstream task is defined. Vision models such as DINOv2 learn transferable features through self-supervised training [43], and pathology foundation models adapt this principle to tissue tiles or whole-slide images. A pretrained pathology model converts a slide into a fixed numerical vector that can support many cancer-specific analyses without retraining the image encoder. The downstream model still determines how those features are used, so performance reflects the released embedding pipeline and the selected prediction method.")
doc.add_paragraph("We evaluated three released embedding pipelines, each comprising its upstream preprocessing, physical-resolution assumptions, encoder architecture, released layer and representation-learning exposure. TITAN is a multimodal whole-slide model trained with visual self-supervision and vision-language alignment; its published Mass-340K pretraining corpus excluded TCGA, although its developers used TCGA for downstream evaluation [16]. Giga-SSL is a gigapixel self-supervised whole-slide representation whose official repository distributes 512-dimensional TCGA embeddings [39]; its developers used TCGA during model development, and we cannot exclude direct overlap between representation-learning images and the slides evaluated here. Prov-GigaPath combines a tile encoder with a long-context slide encoder trained on Providence health-system pathology data; we used the final 768-dimensional slide layer from the public TCGA embedding dataset [40]. We did not fine-tune model weights or use downstream molecular labels during representation learning in this study. Giga-SSL therefore remains label-held-out in downstream cross-validation, although representation learning may have included the evaluation images. We did not harmonise pixel preprocessing or physical input resolution. The matched analysis compares the released embedding pipelines under a common 1-to-20-component PLS-based probe rather than isolating intrinsic foundation-model quality.")
doc.add_paragraph("In this study, a cancer-endpoint pair denotes one TCGA cancer type combined with one outcome, for example COAD with APC mutation or LIHC with the wound-healing score. Each pair defines a cancer-specific prediction task, not a pair of patients. For every eligible pair, we analysed only patients from that cancer who had the required outcome label. We then fitted a separate model for each available representation. In the matched benchmark, we used identical patients and validation folds for TITAN, Giga-SSL and Prov-GigaPath, and we never pooled different cancer types in one prediction model.")
doc.add_paragraph("A practical feature of the fitted analysis is model portability. PLS, PLS–LDA and ridge predictors can all be represented by compact learned preprocessing and coefficient objects and applied without release of patient-level training embeddings or outcomes. Portability therefore motivates comparison within the linear-model family but is not a unique advantage of PLS. It supports external research testing while minimising distribution of patient-level data, but does not itself establish privacy, licensing compatibility or transportability.")
doc.add_paragraph("We first compared the three representations in the same 8,241 patients, using 3,389 cancer-endpoint tasks and identical validation folds. We then used the larger TITAN cohort for a supporting permutation and multiplicity-controlled screen. Finally, we implemented the fitted research models in PathoFMPred, which selects the appropriate feature schema and cancer-specific model for TITAN, Giga-SSL or Prov-GigaPath input. The package supports reproducible external research testing, but it is not the main scientific result and does not add validation evidence.")
doc.add_paragraph("Our primary objective was to identify which tumour features routine histology could predict within each cancer and which signals remained visible across TITAN, Giga-SSL and Prov-GigaPath. We evaluated directly observed mutations and fusions, MSI, genome doubling and oncogenic-pathway status, together with sequencing-derived burdens, transcriptomic inflammatory programmes, inferred immune-cell fractions and composite tissue-context phenotypes. We then tested whether the strongest associations persisted across alternative partitions and tissue-source-site-code grouping. Here, predictability means cross-validated agreement with the supplied reference label. It does not imply causality, mechanism, analytical recovery of the originating assay or assay replacement. We did not analyse molecular subtype.")

doc.add_heading("Methods", level=1)
doc.add_heading("Study design, slides and patient unit", level=2)
doc.add_paragraph(f"A total of {n_slides:,} eligible primary-tumour diagnostic slides (TCGA sample type 01 and –DX filename) from {n_patients:,} participants were identified in the published TITAN TCGA table. For the {n_multi:,} participants with multiple eligible slides, one patient vector was obtained by feature-wise arithmetic mean before outcomes were joined. The patient, rather than the slide, was used as the unit of analysis and cross-validation. Within a patient, every eligible slide was assigned weight 1/n; after pooling, one row and therefore one observational unit were contributed by every participant. Exact filename matches to TITAN's TCGA-Slide-Reports.csv were obtained for {n_exact_reports:,} selected slides; an exact report row was unavailable for {n_unmatched_reports:,} slides. Report metadata were used only for auditing identifiers, project/cancer provenance and anatomical resection/biopsy-site annotations, and no report text was entered into a model. The two-character tissue-source-site code used for grouped validation was derived directly from the TCGA participant barcode. The {n_missing_cancer:,} participants without a resolvable cancer label were excluded from cancer-specific modelling. Eligible slides from more than one primary sample barcode were not identified for any participant.")
doc.add_paragraph("No structured tumour-content/cellularity percentage, tissue-area measurement, artefact assessment, biopsy-versus-resection indicator or slide/image-quality score was available in the TITAN feature table or TCGA-Slide-Reports.csv; accordingly, none was used for slide exclusion or weighting. An anatomical site, rather than a specimen procedure, is recorded in the field named site_of_resection_or_biopsy. Generated slide narratives were audited only for transparency and were not treated as independent pathologist-adjudicated QC labels. Eligibility was therefore based on TCGA sample type and diagnostic-slide filename rather than prospective pathology review.")
doc.add_paragraph("All models were stratified by cancer type. Pan-cancer differences were not learned by any model, and each patient was restricted to one validation fold. Discovery-stage prioritisation, rather than diagnosis, treatment selection or replacement of molecular testing, was specified as the intended use.")
doc.add_paragraph("All available eligible TCGA participants were included; no formal power calculation was performed. Minimum outcome-specific denominators were set according to the documented analysis rules in the initial repository snapshot and were chosen to support nested folds. Treatments were not modelled because the endpoints were contemporaneous molecular or derived immune/genomic features rather than prognosis or treatment response.")
doc.add_paragraph("Reporting was audited against TRIPOD+AI [28]. Participant characteristics were linked from the TCGA Clinical Data Resource [29] and summarized overall and by cancer. These fields were not supplied to prediction models. In a post hoc denominator-first audit, a cancer–endpoint model was considered high volume at ≥200 outcome-labelled patients. Performance was recalculated within the fixed five-repeat held-out predictions when a continuous subgroup contained ≥50 patients or a binary subgroup contained ≥20 positive and ≥20 negative patients. Recorded sex was obtained from the TCGA CDR gender field; White, Black or African American, Asian and other recorded broad-race categories were retained separately. Q², RMSE and Spearman correlation were used as continuous subgroup metrics; sensitivity, specificity, balanced accuracy, AUROC and PR-AUC were used as binary metrics. No subgroup-specific model was refitted, no formal between-group hypothesis test or multiplicity correction was performed, and the audit was not designed to establish fairness. Exact counts and reasons for non-estimability were retained for every model–subgroup row.")
doc.add_paragraph("The mutation-literature comparison was conducted as a targeted narrative cross-check rather than a systematic review. PubMed was last searched on 24 August 2026 using combinations of ‘histology’, ‘H&E’ or ‘whole-slide image’ with ‘mutation’ or ‘genomic alteration’, ‘prediction’ or ‘deep learning’, and ‘cancer’; ‘computational pathology’ with ‘molecular biomarker prediction’, ‘pan-cancer’ with ‘TCGA’, and ‘thymoma’ with ‘GTF2I’ were combined in additional searches. Backward and forward citations of the principal pan-cancer and endpoint-specific studies were checked, including primary-study supplementary tables. Prediction of a mappable mutation or molecular feature from routine histology in human tumours was required for eligibility. Morphology-only associations, non-histological predictors, prognosis-only studies and reviews without primary performance results were excluded. Preprints were retained only as preliminary evidence. Pooled colorectal evidence was mapped to both COAD and READ but labelled ‘pooled colorectal’; precedence was given to exact-cancer evidence. Screening and extraction were performed by one investigator without duplicate review or formal risk-of-bias assessment. The complete queries, rules, evidence scope and source links are provided in Supplementary Methods and literature_crosscheck_method.csv.")
doc.add_heading("Predictors and outcomes", level=2)
doc.add_paragraph("Five pragmatic inclusion criteria were applied to the matched comparison: a released slide-level TCGA embedding artifact had to be accessible for research use without downloading or reprocessing slide pixels; a deterministic TCGA slide identifier linkable to participant and cancer had to be retained; one fixed-length slide vector suitable for identical patient pooling and linear probing had to be provided; the 32-cancer task frame had to be covered with sufficient overlap for a common-patient analysis; and a materially distinct published whole-slide pretraining or aggregation strategy had to be represented. All five criteria were met by TITAN, Giga-SSL and Prov-GigaPath in the project snapshot. Models without compatible precomputed TCGA slide vectors, adequate identifiers or common-cohort coverage were excluded from this pragmatic benchmark even when weights or tile-level encoders were available. Representative alternatives and the criterion that prevented inclusion are listed in Supplementary Table S15e and foundation_model_exclusion_inventory.csv. The selection was designed for reproducible comparison of released embedding pipelines, not as an exhaustive catalogue or ranking of pathology foundation models. Because its code and initial results first appeared together, these settings are documented as fixed rather than prospectively specified.")
doc.add_paragraph("Fixed pretrained whole-slide representations were included as predictors: 768 TITAN dimensions [16], 512 Giga-SSL dimensions [39] and the final 768-dimensional Prov-GigaPath slide layer [40]. The TITAN artifact was obtained from the official gated Hugging Face release; Giga-SSL embeddings were taken from the official GitHub release at commit 605b950 [41]; and Prov-GigaPath embeddings were obtained from the public seandavis/tcga_provgigapath_embeddings Hugging Face dataset at local source snapshot commit 073115403c2fc5134ee8d1332c603edba591dddb [42]. Slide identifiers, deterministic feature names and SHA-256 provenance were preserved by the conversion scripts. Repeated filename records, whose origin was not explained in the dataset card, were present in the downloaded Prov-GigaPath Parquet: 1,406 excess rows across 1,402 duplicated slide identifiers. All repeated final-layer vectors were exactly identical. The first occurrence was retained and all 1,406 exact duplicate Prov-GigaPath rows were removed before slide filtering or patient pooling, so a slide's or patient's weight could not be increased by a repeated source row. No slide pixels were downloaded or reprocessed for the added representations and no foundation-model weights were fine-tuned.")
doc.add_paragraph("Continuous outcomes comprised 39 immune/inflammatory measures and 11 genomic-context scores from Thorsson et al. [19], three aneuploidy burdens from Taylor et al. [20], log-transformed fusion burden from Gao et al. [21], and MANTIS/MSIsensor scores from Bonneville et al. and the cBioPortal TCGA PanCancer Atlas files [22,23]. Binary outcomes comprised qualifying protein-altering PASS mutations in tissue-specific consensus cancer genes from MC3 and Bailey et al. [24,25], ten oncogenic-pathway alteration indicators [26], genome doubling [20], any called fusion and eligible recurrent fusion pairs [21], and MSI-H definitions at MANTIS >0.4 and a strict >0.6 sensitivity threshold [22].")
doc.add_paragraph(f"For the representation comparison, each representation was independently mean-pooled across eligible primary-tumour diagnostic slides. A total of {foundation_common_n:,} patients were included in the intersection. Identical outcome-labelled patients, outer folds, seeds, a 1-to-20-component grid and default fastPLS rSVD settings were used for all three representations in every cancer-endpoint task. All 2,963 continuous and 426 binary tasks meeting eligibility on this common cohort were included in the comparison; neither targets nor examples were selected using a representation's performance. Q² was specified as the primary continuous estimand, with RMSE and Spearman correlation as secondary metrics. For binary tasks, the component count was selected by pooled inner out-of-fold AUROC. Outer out-of-fold AUROC was specified as the primary paired statistic, and the descriptive crossing was defined as AUROC at least 0.60. PR-AUC was reported with the observed TCGA prevalence as its no-skill reference. A balanced-accuracy-maximising threshold was learned from pooled inner out-of-fold training scores and applied unchanged to each outer test fold. Sensitivity, specificity, balanced accuracy, PPV and NPV were calculated at this training-derived operating point. The comparison therefore estimates the performance of each released embedding pipeline under this common PLS-based probe and does not establish its best achievable performance under another prediction method. The analysis was treated as an internal TCGA representation-probe benchmark, not external validation.")
doc.add_paragraph("For each cancer-endpoint pair, the leading representation was defined as the pipeline with the highest observed patient-level out-of-fold Q² for a continuous endpoint or AUROC for a binary endpoint under the common probe. This rank was used only as a descriptive comparison. Statistical superiority was not established by a small difference, and the leading pipeline could change with the fold assignment, component range or downstream method.")
doc.add_paragraph("Catalogue breadth was summarized four ways for each representation and outcome type: the percentage of eligible cancer-endpoint tasks crossing the effect threshold; the percentage of unique endpoint definitions with at least one crossing; the unweighted mean of within-family crossing percentages; and the unweighted mean of within-cancer crossing percentages. An endpoint definition was the exact family-endpoint-source combination, irrespective of cancer. The matched atlas contained 239 definitions, including 108 continuous and 131 binary definitions. For every endpoint definition and broader biological programme, the number and identity of eligible cancers retaining it were counted. These summaries reduce the influence of large correlated endpoint families but do not convert task counts into independent biological discoveries.")
doc.add_paragraph("Endpoint provenance was audited independently of model performance. Every task was classified as a directly observed genomic alteration, sequencing-derived continuous burden, computationally inferred immune-cell fraction, transcriptomic signature, composite genomic-context score or pathology-associated quantity. TIL Regional Fraction was additionally flagged as same-H&E because both predictor and reference phenotype originated from H&E images. Crossing counts were calculated separately within these classes and continuous and total counts were recalculated after excluding same-H&E tasks. CIBERSORT fractions, methylation-derived leukocyte fractions and RNA signatures are interpreted as agreement with another computational phenotype, not recovery of directly measured immune-cell abundance. Representative translational examples were selected within provenance classes using the continuous Q² or AUROC estimates, alternative-partition medians and ranks, crossing proportions, grouped effects and grouped-minus-matched-random changes. Threshold categories were not used as biological evidence grades.")
doc.add_paragraph(
    f"Sensitivity to grouping by a barcode-derived cohort-structure variable was evaluated for all {foundation_union_counts['tasks']} cancer-endpoint pairs that crossed its documented threshold in at least one representation. Within each task, complete two-character TCGA tissue-source-site codes were assigned to one outer fold and were also kept intact during inner component selection. TITAN, Giga-SSL and Prov-GigaPath used the same outcome-labelled patients, grouped folds and seeds. A matched-random control preserved every grouped outer fold's patient count and, for binary outcomes, its positive and negative counts, while allowing codes to mix. Of {len(foundation_tss_grouped):,} representation-task fits, {len(foundation_tss_feasible_rows):,} were estimable. ACC genome doubling was not estimable for any representation because one grouped inner training partition contained a single class. The realized outer-fold count is an explicit task-level field: 4 rather than 5 folds were used for 10 tasks (4 binary and 6 continuous) because only 4 complete codes were available. Tasks contained {foundation_tss_code_min}-{foundation_tss_code_max} contributing codes. This is sensitivity to grouping by a barcode-derived cohort-structure variable, not validation by institution, scanner, laboratory or staining batch and not evidence of generalisability."
)
doc.add_paragraph("Grouped outer performance was calculated once from all pooled patient-level out-of-fold predictions; fold-specific metrics were not averaged. A binary outer test fold containing one class therefore contributed predictions to the pooled task-level sensitivity, specificity, balanced accuracy, AUROC and PR-AUC, but no stand-alone fold metric was interpreted. Component selection likewise used the pooled inner out-of-fold predictions. The fold audit records realized outer and inner fold counts, contributing code counts, minimum and maximum test sizes, minimum training-class counts, and single-class outer-test, inner-validation and inner-training indicators. A compact 'sparse grouped folds' flag is triggered by fewer than five outer folds, an outer test set with fewer than 10 patients, any single-class binary outer test/inner validation/inner training fold, or fewer than 20 minority-class patients in any binary outer or inner training fit. These thresholds are descriptive audit triggers, not exclusion, validity or evidence-grade boundaries.")
doc.add_paragraph("Representation consensus, sample size and sensitivity to grouped partitioning were retained as separate task-level fields. Sample size was labelled only as a larger-sample stratum (at least 100 outcome-labelled patients for continuous tasks or at least 50 patients per class for binary tasks) or smaller-sample stratum. The previous R1–R4 composite is retained solely as a deprecated machine-registry navigation tag for backward compatibility; it is not used to rank main-text examples, define biological priorities or modify any performance estimate, p-value or q-value. The sample-size cut-offs are descriptors of development denominators, not evidence grades or guarantees of stability.")
doc.add_paragraph("For the matched three-representation atlas, a performance-threshold crossing was defined as Q²≥0.20 for a continuous task or AUROC≥0.60 for a binary task. These descriptive crossings did not require representation-specific permutation p-values or multiplicity-adjusted q-values and are not called screen-positive discoveries. The term screen-positive is reserved for the secondary TITAN inferential layer, where both the effect threshold and the permutation/FDR rules documented in the initial repository snapshot were satisfied.")
doc.add_paragraph(f"Every primary-partition union-positive task and any task for which at least one representation lay within 0.05 of Q²=0.20 or AUROC=0.60 were included in the fold-assignment and threshold-stability audit. In total, {len(foundation_fold_selection)} unique cancer–endpoint pairs were selected. Each was rerun on five new nested partitions; outcome-labelled patients, fold assignments, seeds, component range and tuning rules were identical across the three representations within every task and repeat. The primary partition was retained separately. Each representation's crossing proportion, Q² or AUROC effect and rank, the proportion of repeats assigned to each consensus class, and threshold curves over Q² 0.10–0.30 and AUROC 0.55–0.65 are reported. These are internal stability estimates, not external validation or representation-specific multiplicity-controlled tests.")
if foundation_slide_audit:
    doc.add_paragraph(
        f"Slide matching was not assumed from patient matching. Slide identifiers were normalised case-insensitively, and the complete within-patient slide set in each embedding resource was audited. Among {ival(foundation_slide_audit.get('common_patients')):,} common patients, {ival(foundation_slide_audit.get('identical_slide_set_patients')):,} ({fnum(foundation_slide_audit.get('identical_slide_set_percent'), 2)}%) had exactly identical slide sets. The common-patient cohort contained {ival(foundation_slide_audit.get('titan_slides_common_patients')):,} TITAN, {ival(foundation_slide_audit.get('gigassl_slides_common_patients')):,} Giga-SSL and {ival(foundation_slide_audit.get('provgigapath_slides_common_patients')):,} Prov-GigaPath slides. The exact three-way slide intersection contained {ival(foundation_slide_audit.get('exact_common_slides')):,} slides and retained all {ival(foundation_slide_audit.get('patients_retained_exact_common_slide')):,} patients. Every patient vector was rebuilt using only this exact slide intersection, and the complete three-representation nested benchmark was repeated as a sensitivity analysis."
    )
doc.add_paragraph("The Thorsson Nonsilent Mutation Rate, Silent Mutation Rate, SNV Neoantigens, Indel Neoantigens and Number of Segments variables, and the Gao fusion burden, were analysed as log(1+x); all other continuous endpoints retained their source scale. Reported RMSE values therefore use these analysed units.")
doc.add_paragraph(f"The Thorsson umbrella does not denote a single immune assay. Its targets include CIBERSORT relative leukocyte fractions inferred by deconvolving bulk RNA sequencing [37], a leukocyte fraction inferred from DNA methylation, bulk-RNA gene-set signatures, BCR/TCR repertoire quantities reconstructed from RNA sequencing, in-silico neoantigen burdens, purity- and copy-number-derived genomic-context scores, and TIL Regional Fraction inferred from H&E by the Saltz deep-learning workflow [19,38]. The last target is a same-histology-modality concordance task rather than a cross-modal endpoint. None of these inferred quantities is treated as equivalent to flow cytometry, immunohistochemistry, a directly counted immune-cell assay or a clinically certified biomarker. The {len(endpoint_dictionary):,}-row endpoint dictionary records source modality, direct or inferred status, derivation, source scale, transformation, outcome-specific missingness, expected measurement error, biological interpretation and an assay-equivalence caveat for every modelled target; its {len(endpoint_definitions):,} unique definitions are supplied separately.")
doc.add_paragraph(f"Molecular missingness was retained rather than converted to a negative label, and no outcome imputation was performed. TCGA case and sample identifiers were resolved against the Genomic Data Commons case resources [33]. Mutation status was defined only among {n_mc3_profiled:,} embedding patients matched to an MC3 primary-tumour profile; {n_mc3_missing:,} embedding patients without such a profile were excluded from mutation denominators. Within this profiled set, wild type meant no qualifying PASS protein-altering variant in the specified gene. Fusion-negative status was assigned only within the Gao study sample list. Multiple primary aliquots, if present, were collapsed at patient level by any alteration for binary mutation/pathway/fusion endpoints and by the documented mean or any-positive rule for continuous or binary instability endpoints. The source-level coverage table records covered patients, missing patients, aliquot multiplicity and aggregation for every cancer and source; no source contained multiple primary aliquots among matched embedding patients in this release.")
doc.add_paragraph("Continuous pairs required at least 50 non-missing patients. Binary screening eligibility required at least 20 positive and 20 negative patients. Eligibility was decided before modelling and every eligible test remained in every applicable multiplicity denominator. Because these inclusive limits can produce development instability, binary candidates below 50 patients per class and continuous candidates below 100 labelled patients are retained in the inclusive atlas as the smaller-sample stratum and excluded from default inference. The ≥50-per-class and ≥100-patient rules do not change eligibility, threshold crossing, raw p-values, q-values, statistical significance or the complete atlas and must not be interpreted as retrospective significance filters or evidence grades.")
doc.add_paragraph("For every continuous candidate, the reliability audit summarized sample size, the standard deviation of Q² across five independently seeded nested-CV repeats, and the mean of the ten pairwise Spearman correlations between patient-level repeated out-of-fold predictions. It also recovered the selected component count from all 25 repeated outer fits and recorded selection of the 20-component ceiling. Associations of sample size with mean Q² and prediction stability were assessed descriptively by Spearman correlation; no causal sample-size effect was inferred.")

doc.add_heading("PLS regression and PLS-LDA classification", level=2)
doc.add_paragraph("Established PLS and PLS-DA validation principles were followed for partial least-squares regression and PLS-based discriminant analysis [17,18].")
doc.add_paragraph("For each cancer-endpoint pair, performance was estimated in five outer folds and 1 to 20 PLS components were selected in the inner folds. Inner held-out predictions were pooled before the tuning statistic was calculated; fold-specific metrics were not averaged. Pooled inner out-of-fold root-mean-square deviation was minimised for continuous component selection. Pooled inner out-of-fold AUROC from the continuous class-1-minus-class-0 PLS-LDA discriminant score was maximised for binary component selection. The smallest component count was selected when exact metric ties occurred. After component selection, the threshold that maximised balanced accuracy on the same pooled inner training predictions was selected and applied unchanged to the outer test fold. Only training patients were used for centering, component selection and threshold selection. The same component range was used for the 512-dimensional Giga-SSL and 768-dimensional TITAN and Prov-GigaPath inputs. Constant and near-constant dimensions were audited by representation; no global variance filtering was performed before nested fitting. The five exactly constant Giga-SSL dimensions were retained to preserve the released 512-column schema. Each was mapped to zero by training-fold centering and therefore could not contribute to covariance, latent scores, loadings or effective rank. CPU rSVD used the fastPLS 0.3 defaults of 32 oversampling vectors and five power iterations with explicit seeds. Continuous performance was assessed by out-of-fold Q², with RMSE and Spearman correlation as secondary metrics. Binary performance was assessed by AUROC as the primary paired statistic and by PR-AUC plus training-threshold operating metrics as secondary statistics.")
doc.add_paragraph("Q² was calculated as 1−Σ(y−ŷ)²/Σ(y−ȳ)² over outer-fold predictions, and RMSE was calculated as the square root of the mean squared prediction error. For binary outcomes, class 1 was defined as altered or positive and class 0 as wild type or negative within the outcome-specific covered denominator. Sensitivity was defined as the class-1 true-positive rate, specificity as the class-0 true-negative rate, and balanced accuracy as their arithmetic mean. AUROC was calculated from the continuous class-1-minus-class-0 LDA discriminant score. PR-AUC was calculated as non-interpolated average precision, so its no-skill reference was equal to outcome prevalence. Positive and negative predictive values (PPV and NPV) were calculated from held-out class calls at the observed outcome prevalence in the analysed TCGA cohort; they are cohort-specific descriptive estimates, not calibrated probabilities or transportable operating characteristics. Spearman correlation was calculated between observed and held-out continuous predictions.")
doc.add_paragraph(f"As a secondary algorithmic benchmark, targets were selected from all {len(continuous) + len(binary):,} eligible TITAN cancer-endpoint tests without using PLS performance. Continuous and binary sampling frames were divided into empirical sample-size terciles; binary endpoints were additionally divided into empirical terciles of minority-class fraction. Within each non-empty outcome-family and sample-size cell, and each binary family, size and imbalance cell, the endpoint with the lowest salted SHA-256 rank was selected. The fixed rule yielded {len(ridge_continuous)} continuous and {len(ridge_binary)} binary targets. The complete sampling frame, salt, hashes and selected jobs are released. This is a representative metadata-stratified comparison, not an atlas-wide fit of ridge to every endpoint.")
doc.add_paragraph("Each selected target was fitted across five repeated nested partitions using PLS regression or PLS-LDA and ridge-penalised Gaussian or logistic regression. Within every repeat, identical patients, outer folds and inner folds were used by both methods. For continuous outcomes, the PLS component count and ridge penalty were selected to maximise pooled inner out-of-fold Q²; maximising Q² is equivalent to minimising pooled squared error because the validation outcome denominator is fixed. For binary outcomes, each method's operating threshold was selected to maximise balanced accuracy on its own inner out-of-fold continuous scores, without access to the outer test fold. Threshold-independent AUROC and symmetrically thresholded balanced accuracy were reported as complementary algorithm-comparison metrics; Q² and Spearman correlation were used for continuous comparisons. For repeat r, d_r=M_r(ridge)−M_r(PLS) and Δ=(1/5)Σ_r d_r. In 2,000 paired patient-resampling replicates, patients were sampled with replacement, both methods and all five matched predictions were retained, and d_r and Δ were recalculated; the interval was formed by percentiles 2.5 and 97.5. Metadata-stratified target selection was not repeated, new partitions were not generated and neither algorithm was refitted within the interval calculation. Ridge was chosen as a simple portable linear baseline; portability is not unique to PLS.")
doc.add_paragraph("No class under-sampling, over-sampling or synthetic augmentation was used. An uncalibrated discriminant score, rather than a probability or clinical-risk threshold, was returned by the binary pipeline. For every one of the 426 matched binary pairs and each representation, the component count was selected by pooled inner AUROC, and a balanced-accuracy threshold selected from those training-only scores was applied. On the same selected component and unchanged outer scores, empirical-training-prior and equal-prior calls were also generated in the operating-rule sensitivity. Continuous paired changes in balanced accuracy, sensitivity, specificity, PPV and NPV across the three rules are reported. AUROC and PR-AUC remain identical across these three call rules because the score and selected component are fixed. Operating-point dependence is evaluated by this sensitivity; probability calibration, external validation and representation-specific permutation/FDR testing are not provided. Outcome tables were constructed independently of embedding processing and joined only after patient-level aggregation.")
doc.add_paragraph("Nested performance was first checkpointed for the complete screen. Only models with Q² at least 0.20 or chance-corrected balanced accuracy at least 0.20 entered permutation testing. Chance-corrected balanced accuracy was defined as twice balanced accuracy minus one; therefore a value of 0.20 corresponds to balanced accuracy 0.60. Every eligible model below this checkpoint was not permuted and was conservatively assigned raw p=1. Models that entered permutation testing but reached the conservative early-stopping boundary also received p=1. All eligible rows remained in every applicable Benjamini-Hochberg denominator. For every performed permutation, patient labels were reassigned and the complete modelling process was repeated, including training-fold centering, five-fold inner selection of 1 to 20 components, outer-fold refitting and held-out prediction. A 99-permutation checkpoint was followed by refinement toward 999 permutations, with 9,999 permutations for selected leading claims. Completed finite p values used (b+1)/(B+1), and exact two-sided 95% Clopper-Pearson intervals quantified Monte Carlo uncertainty.")
doc.add_paragraph("Under the documented TITAN-screen rules, Benjamini–Hochberg FDR was controlled separately for continuous and binary outcomes within each cancer and endpoint family [27]. The row-level audit reproduced every q-value and found local BH denominators of 1 to 52 continuous or 1 to 48 binary tests, across-cancer/family denominators of 30 to 1,560 or 3 to 238, outcome-wide denominators of 3,174 or 459, and one atlas-wide denominator of 3,633. Two stricter sensitivities were retained: BH across cancers within the same outcome type and family, and a single BH correction across every eligible continuous and binary test. Eight targets were locked in a separate pre-result commit before their saved permutation streams were extended from 999 to 9,999 complete-process permutations. The screening statistic was Q² for continuous outcomes and 2×balanced accuracy−1 for binary outcomes. Screening tier A required primary q<0.05 and a statistic of at least 0.40; tier B required primary q<0.05 and a statistic from 0.20 to less than 0.40. For binary outcomes these cut-offs corresponded to balanced accuracy of at least 0.70 and 0.60 to less than 0.70. The tiers were used for prioritisation and were not interpreted as clinical categories or as commensurate effect sizes across outcome types.")

doc.add_heading("Robustness and saved models", level=2)
doc.add_paragraph("The initial nested-CV estimate used for candidate screening, permutation testing and tier assignment is termed the primary screening estimate. Only endpoints passing that initial atlas screen entered five additional independently seeded nested-CV partitions; their reported repeated-validation estimate is the arithmetic mean of the five repeat-specific metrics. Different questions are addressed by the two estimates, which need not be numerically identical because different fold partitions and rSVD seeds are used. The selection and multiplicity path documented in the initial repository snapshot is preserved by the primary screening estimate, whereas post-selection resampling stability is described by the five-repeat estimate; screen membership is not replaced or retroactively altered. For example, THYM–Th17 had primary screening Q²=0.638 and five-repeat mean Q²=0.594. Both fold construction and rSVD were governed by each repeat seed. Sensitivity, specificity, balanced accuracy and AUROC were calculated within each repeat for binary endpoints; Q², RMSE and Spearman correlation were calculated within each repeat for continuous endpoints. LDA scores from independently fitted repeats were never pooled onto an assumed common scale. For highlighted models, all five existing held-out predictions for each sampled patient were retained in 1,000 patient-cluster bootstrap resamples; the metric was recalculated within each repeat and the five repeat metrics were then averaged. The reported 95% selection-conditioned patient-resampling interval for repeated out-of-fold predictions was formed by the 2.5th and 97.5th percentiles. Patient sampling variability conditional on the five fitted nested-CV prediction sets is represented by this interval. The initial screen and endpoint highlighting, new partition generation, scaling or component reselection, model refitting inside bootstrap replicates, winner's-curse correction, and external cohort, institution, scanner and population variation are not included. Under validation grouped by TCGA tissue-source-site code, all patients sharing the same two-character code were assigned to one outer fold. The same constraint on TCGA tissue-source-site code was passed to every inner component-selection split within the outer training set; thus a code was divided across folds by neither outer performance estimation nor inner tuning. For every model and outer fold, test and training patients, TCGA tissue-source-site codes, and, where applicable, positive and negative cases were recorded. In the pooling sensitivity, the arithmetic mean was replaced with either the coordinate-wise median or the lexicographically first eligible diagnostic slide while patients, seeds, rSVD settings and nested-CV rules were preserved. For every released representation, numerical within-patient heterogeneity was summarized by pairwise slide cosine distance, slide-to-centroid distance, mean-versus-median centroid distance and the maximum change in the patient centroid after leaving out one slide. The 30-slide SARC participant was additionally removed before fold construction and every SARC candidate was refitted. Full-data research models were tuned by ten-fold CV and saved with feature order and checksum, training ranges, aggregation rule, endpoint transformation and output units, class coding and priors, decision rule, calibration status, class counts, exact software version and commit, computation backend, rSVD controls, external-validation status and intended-use metadata.")
doc.add_paragraph("Molecular–slide linkage was audited at the unique patient-by-source level. Diagnostic WSI identifiers were reduced to the 15-character TCGA sample barcode. Taylor aneuploidy, Sanchez-Vega pathway, Gao fusion, cBioPortal MSI and MC3 mutation resources supplied sample identifiers, allowing same-sample concordance to be counted; the Thorsson PanImmune table supplied only a participant barcode, so exact sample linkage was not estimable. A shared 15-character barcode establishes the same TCGA sample/specimen category but not identity of the tissue portion, analyte, aliquot, block or tumour region. Sources with multiple primary samples were collapsed by the documented patient-level rule. These unavoidable resolution limits were retained as source-specific label-noise metadata rather than treated as exclusions.")
doc.add_paragraph("For every screen-positive binary model, positive and negative counts were recorded in all 25 repeated outer test folds, and the exact five-fold inner component-selection partitions were reconstructed within every outer training set. The selected-component distribution was summarized across the resulting 25 fits. Repeat stability was quantified using pairwise Spearman correlations of patient-level standardized held-out scores and agreement of held-out class calls across repeats. For the limited-evidence subset, each repeat's original outer test fold was retained in the learning curves while models were fitted on stratified 50%, 75% and 100% subsets of the outer training data; the five repeats were analysed separately. Training-size sensitivity is isolated by this design without patients being moved between training and evaluation. Sparse internal validation is not converted into external evidence by these analyses.")
doc.add_paragraph("To quantify whether information about TCGA tissue-source-site code was retained by TITAN itself, that code was treated as a multiclass outcome within each cancer. Codes represented by at least 10 patients were retained in this dedicated association analysis, at least two eligible codes were required per cancer, and five independently seeded nested five-fold PLS–LDA validations were performed with the same component range and rSVD controls. Multiclass macro balanced accuracy (mean recall across TCGA tissue-source-site codes) was used as the primary metric; chance was 1/k for k analysed codes, and a chance-normalised value, (balanced accuracy − 1/k)/(1 − 1/k), was calculated for cross-cancer description. Patients with rare codes excluded from this code-classification analysis remained in all eligible molecular-endpoint analyses. Whether signatures associated with TCGA tissue-source-site code were encoded by the representation was tested; their scanner, laboratory, staining, population or biological causes were not identified, and confounding of a molecular endpoint was not established.")
doc.add_paragraph(f"Four controls were added to separate generic partition difficulty from code-associated outcome distribution shift. First, for each of the {titan_candidate_total} TITAN candidates, every grouped fold's test-set size was reproduced by a matched random outer partition; for binary endpoints, the positive and negative counts were also reproduced exactly. Grouped and matched-random models were refitted with the same patients, component range and outer-fit seeds; codes were kept intact in grouped inner folds, whereas matched-random inner folds were unconstrained. Second, both held-out predictions were retained in 1,000 paired patient-resampling replicates, from which a percentile interval for grouped-minus-matched-random Q² or balanced accuracy was produced. Third, continuous outcomes were predicted in code-only cross-validation using training-fold code means and binary outcomes using training-fold code prevalence, with the training-fold global mean used for unseen codes; outcome information available from code alone was quantified by Q² or AUROC. Fourth, continuous outcome heterogeneity was measured by code eta-squared and binary heterogeneity by the maximum-minus-minimum code-specific prevalence. These are descriptive internal controls. Technical acquisition cannot be distinguished from biological case mix, subtype, ancestry or referral patterns by these controls. Fixed-effect residualisation was not used as primary evidence because no training-set code effect can be estimated for a held-out code and the grouped-validation estimand would be changed by such adjustment.")
doc.add_paragraph("For qualitative morphological context, five representative models were selected to span an H&E-derived TIL quantity, an RNA-derived CIBERSORT fraction, an RNA-expression signature, a copy-number burden and a sequence-supported mutation. Within each model, high and low anchors were chosen from concordant extremes of mean repeated out-of-fold predictions. The closest within-cancer patient was then retrieved by cosine similarity of patient-level mean TITAN representations. For display only, a report-covered slide closest to each patient mean was selected deterministically, and a fixed list of morphological terms was extracted from TITAN-generated TCGA-Slide-Reports text. Neither report text nor example selection entered model fitting. Only global 768-dimensional pooled representations were available; no patch embeddings, attention maps or slide pixels were retained. Descriptive nearest-neighbour context, rather than patch-level relevance, causal attribution or blinded pathologist review, is therefore provided by this analysis.")
doc.add_paragraph("TITAN, Giga-SSL or Prov-GigaPath features are accepted by PathoFMPred through an explicit foundation_model argument, and the representation-specific feature schema is validated before patient-level pooling. Binary LDA scores are retained but are not converted to probabilities. In research outputs, the TCGA out-of-fold score rank is labelled as not a probability, and training denominators and evidence warnings are placed beside each estimate. External validation or clinical suitability is not implied by representation availability in the package.")
doc.add_paragraph("When multiple representation-specific objects exist for one cancer–endpoint task, controlled-object availability is listed by compare_pathofm_models() separately from the recorded representation-specific matched-threshold status, evidence tier and grouped sensitivity where available. Representation consensus is never inferred from the number of stored objects because every representation-specific crossing is not covered by the controlled inventory. The numerically largest internal estimate is not selected automatically, and predictions are not averaged across representations. For an existing embedding, its matching object must be selected; for a new comparative study, the representation and model must be locked before outcome inspection. Prioritisation of atlas-level cross-representation retention, stronger evidential qualification and retained grouped sensitivity is advised by the software, with an explicit statement that external validation cannot be replaced by these internal criteria.")
doc.add_paragraph("The learned transformations and coefficients were stored in portable PLS and PLS-LDA objects without patient-level training rows. The selected representation schema was validated as 768 features for TITAN, 512 for Giga-SSL or 768 for Prov-GigaPath. The public PathoFMPred package contains a minimal Giga-SSL fixture and explicit post-install download functions for the permitted Giga-SSL and Prov-GigaPath collections. TITAN fitted objects were excluded from the public package because their redistribution requires upstream permission. A generic builder was provided so that authorized users can create a local PathoFMPred object from a feature table and an outcome table linked by a required patient identifier; repeated feature rows are aggregated at patient level. The comparison of separate and joint multi-outcome PLS models for inflammatory outcomes is described in the Supplementary Methods.")

doc.add_heading("Software, transparency and validation status", level=2)
doc.add_paragraph("Analyses were performed using R 4.6.0 and fastPLS 0.3 (Git commit b518f75). Analysis code, manifests, complete-resolution results and model registries are provided in the public GPL-3.0 companion repository [30]. PathoFMPred contributor-authored source code and documentation use the MIT licence. The Giga-SSL and Prov-GigaPath fitted collections carry separately stated asset and upstream attribution terms; the TITAN fitted collection is excluded from the public repository. Complete object reconciliation and licensing details are reported in the Supplementary Material and package documentation. No independent cohort was included, so every performance estimate is internal to TCGA.")
doc.add_paragraph("A protocol fixed for future independent evaluation, including immutable model identifiers and endpoint-compatibility rules, is provided in the Supplementary Methods and companion repository. It does not constitute external validation and is not described as prospectively locked for the present retrospective benchmark.")
doc.add_paragraph("Supplementary methods, compact Tables S1-S18, Figures S1-S4 and the machine-readable-file inventory are provided in Additional file 1. The two post hoc illustrative COAD research-software outputs are supplied separately as Additional files 2 and 3.")

doc.add_heading("Results", level=1)
doc.add_heading("Cohort and analysis coverage", level=2)
doc.add_paragraph(f"The full TITAN embedding cohort contained {n_patients:,} patients represented by {n_slides:,} slides; {n_multi:,} patients ({100*n_multi/n_patients:.1f}%) had more than one eligible diagnostic slide. The maximum was 30 slides for {maximum_slide_patient.get('patient', 'one participant')} ({maximum_slide_patient.get('project_id', 'SARC')}); its 30 slides each received weight 1/30 in the pooled vector, while the resulting patient vector had the same downstream observational weight as every other participant. No patient contributed diagnostic slides from more than one 15-character TCGA sample barcode. Exact slide-report coverage was {n_exact_reports:,}/{n_slides:,} ({100*n_exact_reports/n_slides:.1f}%). Cancer labels were available for {n_patients-n_missing_cancer:,} patients across {n_cancers} cancers. The supporting TITAN permutation/FDR screen evaluated {len(continuous):,} continuous and {len(binary):,} binary cancer-endpoint pairs; full family-level counts are in Supplementary Table S1. The primary matched benchmark used 8,241 common patients and 3,389 cancer-endpoint tasks for each representation. Of {len(mutation_eligibility):,} documented cancer-gene mutation pairs with a profiled denominator, {n_mutation_eligible:,} met the 20-positive/20-negative rule and {n_mutation_ineligible:,} were reported as ineligible rather than tested-negative.")
doc.add_paragraph(f"The structured pathology-QC audit confirmed that tumour percentage, tissue area, artefact, specimen procedure and slide quality were unavailable. Among the {ival(pathology_qc.get('exact_report_matched_slides')):,} matched generated slide narratives, tumour-content, tissue-area, artefact and explicit slide-quality phrases occurred in only {ival(pathology_qc.get('tumour_content_mentions'))}, {ival(pathology_qc.get('tissue_area_mentions'))}, {ival(pathology_qc.get('artefact_mentions'))} and {ival(pathology_qc.get('slide_quality_mentions'))} slides, respectively; these unvalidated text mentions did not alter inclusion or weights. All 30 generated narratives for {maximum_slide_patient.get('patient', 'the maximum-slide participant')} stated that no residual sarcoma/myxofibrosarcoma was seen. This finding exposes a clinically important limitation of barcode-based eligibility and is not reinterpreted as an adjudicated exclusion because the narratives were generated from the same images rather than independently reviewed.")
if molecular_slide_linkage:
    sample_link_text = "; ".join(
        f"{r['source']}: {ival(r.get('exact_slide_sample_patients')):,}/{ival(r.get('covered_patients')):,}"
        for r in molecular_slide_linkage
        if r.get("identifier_resolution") != "participant identifier only"
    )
    th_link = linkage_by_source.get("Thorsson2018_PanImmune_MS", {})
    doc.add_paragraph(
        f"Molecular–slide linkage was not uniform across sources. Same 15-character TCGA sample-barcode concordance among embedding-cohort patients covered by each sample-indexed source was {sample_link_text}. The Thorsson table linked {ival(th_link.get('covered_patients')):,} patients only at participant level, so same-sample concordance could not be assessed. Even an exact sample match did not identify the molecular portion, analyte, aliquot, slide block or sampled tumour region; therefore these counts quantify available specimen linkage, not block-level identity (Supplementary Table S3c)."
    )
if participant_overall:
    known_gender = ival(participant_overall.get("female")) + ival(participant_overall.get("male"))
    doc.add_paragraph(
        f'The TCGA Clinical Data Resource [29] matched {ival(participant_overall.get("cdr_matched")):,}/{n_patients:,} participants. '
        f'Age was available for {ival(participant_overall.get("age_available")):,} participants (median {fnum(participant_overall.get("age_median"), 1)} years, IQR {fnum(participant_overall.get("age_q1"), 1)}–{fnum(participant_overall.get("age_q3"), 1)}); '
        f'{ival(participant_overall.get("female")):,}/{known_gender:,} with recorded gender were female. '
        f'Race was recorded for {ival(participant_overall.get("race_available")):,} and broad stage I–IV for {ival(participant_overall.get("stage_available")):,}. '
        "These fields describe cohort composition and support the post hoc subgroup denominator audit below."
    )

doc.add_heading("Primary matched three-representation benchmark", level=2)
doc.add_paragraph(
    f"After identical primary-tumour diagnostic-slide filtering and patient mean pooling, TITAN contained "
    f"{ival(foundation_cohort_by_model['TITAN']['source_slides']):,} slides from {ival(foundation_cohort_by_model['TITAN']['patients']):,} patients, "
    f"Giga-SSL {ival(foundation_cohort_by_model['GigaSSL']['source_slides']):,} slides from {ival(foundation_cohort_by_model['GigaSSL']['patients']):,} patients, and "
    f"Prov-GigaPath {ival(foundation_cohort_by_model['ProvGigaPath']['source_slides']):,} slides from {ival(foundation_cohort_by_model['ProvGigaPath']['patients']):,} patients. "
    f"Their common cohort comprised {foundation_common_n:,} patients. On this intersection, the three representations were evaluated on exactly the same 1,507 continuous and 426 binary cancer–endpoint tasks. "
    "This common-cohort atlas removes patient and endpoint composition as explanations for between-pipeline differences, while remaining conditional on TCGA, each public embedding release and the specified PLS regression/PLS-LDA probe. It does not harmonise upstream pixel preprocessing, physical resolution, representation-learning exposure or the released embedding layer."
)
doc.add_paragraph(
    f"Under the fixed PLS-based probe, continuous/binary task-level crossing rates (Q²≥0.20 or AUROC≥0.60) were {foundation_breadth_label('TITAN', 'continuous')} and {foundation_breadth_label('TITAN', 'binary')} for TITAN, {foundation_breadth_label('ProvGigaPath', 'continuous')} and {foundation_breadth_label('ProvGigaPath', 'binary')} for Prov-GigaPath, and {foundation_breadth_label('GigaSSL', 'continuous')} and {foundation_breadth_label('GigaSSL', 'binary')} for Giga-SSL. Unique endpoint-definition coverage was {foundation_definition_label('TITAN', 'continuous')} and {foundation_definition_label('TITAN', 'binary')} for TITAN, {foundation_definition_label('ProvGigaPath', 'continuous')} and {foundation_definition_label('ProvGigaPath', 'binary')} for Prov-GigaPath, and {foundation_definition_label('GigaSSL', 'continuous')} and {foundation_definition_label('GigaSSL', 'binary')} for Giga-SSL. "
    f"Continuous crossing totals were dominated by Thorsson-derived outcomes: {ival(foundation_breadth_by_key[('TITAN', 'continuous')]['largest_family_crossings'])}/{foundation_crossings('TITAN', 'continuous')} ({fnum(foundation_breadth('TITAN', 'continuous', 'largest_family_share_of_crossings'), 1)}%) for TITAN, {ival(foundation_breadth_by_key[('ProvGigaPath', 'continuous')]['largest_family_crossings'])}/{foundation_crossings('ProvGigaPath', 'continuous')} ({fnum(foundation_breadth('ProvGigaPath', 'continuous', 'largest_family_share_of_crossings'), 1)}%) for Prov-GigaPath and {ival(foundation_breadth_by_key[('GigaSSL', 'continuous')]['largest_family_crossings'])}/{foundation_crossings('GigaSSL', 'continuous')} ({fnum(foundation_breadth('GigaSSL', 'continuous', 'largest_family_share_of_crossings'), 1)}%) for Giga-SSL. Accordingly, raw crossings describe correlated task-level breadth within this catalogue—not independent biological signals or representation-specific permutation/FDR-qualified discoveries. "
    f"Across all matched targets, effect statistics from Giga-SSL and Prov-GigaPath correlated with TITAN at Spearman {fnum(foundation_pairwise_by_key[('GigaSSL versus TITAN', 'continuous')]['spearman_effect'])} and {fnum(foundation_pairwise_by_key[('ProvGigaPath versus TITAN', 'continuous')]['spearman_effect'])} for continuous tasks and {fnum(foundation_pairwise_by_key[('GigaSSL versus TITAN', 'binary')]['spearman_effect'])} and {fnum(foundation_pairwise_by_key[('ProvGigaPath versus TITAN', 'binary')]['spearman_effect'])} for binary tasks. "
    "Under this probe, TITAN had higher target-level effect statistics more often overall, but both alternative pipelines were superior for substantial subsets. The atlas therefore records three complementary layers: associations retained by all pipelines, associations shared by two, and pipeline-specific associations. These results compare released embedding pipelines under a fixed downstream analysis; they do not estimate intrinsic foundation-model superiority. The relevant translational result is whether a candidate is reproducible across pipeline choices and which embedding-pipeline–probe pair should be carried forward—not a universal ranking."
)
doc.add_paragraph(
    f"The provenance-stratified analysis separated direct genomic alterations from derived labels. Among matched directly observed genomic tasks, TITAN, Prov-GigaPath and Giga-SSL crossed {provenance_crossing_label('TITAN', 'binary', 'directly observed genomic alteration')}, {provenance_crossing_label('ProvGigaPath', 'binary', 'directly observed genomic alteration')} and {provenance_crossing_label('GigaSSL', 'binary', 'directly observed genomic alteration')}. Among computationally inferred immune-cell-fraction tasks, the corresponding values were {provenance_crossing_label('TITAN', 'continuous', 'computationally inferred immune-cell fraction')}, {provenance_crossing_label('ProvGigaPath', 'continuous', 'computationally inferred immune-cell fraction')} and {provenance_crossing_label('GigaSSL', 'continuous', 'computationally inferred immune-cell fraction')}. All 11 matched TIL Regional Fraction tasks crossed in every representation, but these were same-H&E concordance tasks. The full 2,073-task endpoint catalogue contained 13 such tasks; two did not meet the common-cohort matched eligibility rules. Excluding the 11 same-H&E tasks reduced continuous crossings from 208/1,507 to 197/1,496 for TITAN, from 130/1,507 to 119/1,496 for Prov-GigaPath and from 105/1,507 to 94/1,496 for Giga-SSL. Thus, neither the same-H&E tasks nor the inferred-phenotype blocks are presented as direct molecular-assay recovery."
)
doc.add_paragraph(
    f"Inclusive and larger-sample counts are reported in parallel. Of the continuous/binary crossings, {foundation_standard_of_crossings('TITAN', 'continuous')} and {foundation_standard_of_crossings('TITAN', 'binary')} met the larger-sample descriptor for TITAN, {foundation_standard_of_crossings('ProvGigaPath', 'continuous')} and {foundation_standard_of_crossings('ProvGigaPath', 'binary')} for Prov-GigaPath, and {foundation_standard_of_crossings('GigaSSL', 'continuous')} and {foundation_standard_of_crossings('GigaSSL', 'binary')} for Giga-SSL. The larger-sample denominators require n≥100 for continuous tasks and at least 50 patients in each binary class. Smaller-sample crossings remain visible in the complete atlas but are not used in unqualified headline examples and are excluded from default PathoFMPred inference."
)
doc.add_paragraph(
    f"The AUROC-centred binary atlas aligned component selection, representation comparison and crossing status. It produced {foundation_crossings('TITAN', 'binary')}, {foundation_crossings('GigaSSL', 'binary')} and {foundation_crossings('ProvGigaPath', 'binary')} AUROC crossings for TITAN, Giga-SSL and Prov-GigaPath. On the identical selected components and outer scores, empirical-prior, equal-prior and training-only optimized calls altered the operating metrics. For TITAN, the median balanced-accuracy change relative to empirical priors was {fnum(binary_operating_value('TITAN', 'equal class priors', 'median_ba_delta_vs_empirical'), 3)} with equal priors and {fnum(binary_operating_value('TITAN', 'training-only optimized threshold', 'median_ba_delta_vs_empirical'), 3)} with the training-only optimized threshold. Corresponding changes were {fnum(binary_operating_value('GigaSSL', 'equal class priors', 'median_ba_delta_vs_empirical'), 3)}/{fnum(binary_operating_value('GigaSSL', 'training-only optimized threshold', 'median_ba_delta_vs_empirical'), 3)} for Giga-SSL and {fnum(binary_operating_value('ProvGigaPath', 'equal class priors', 'median_ba_delta_vs_empirical'), 3)}/{fnum(binary_operating_value('ProvGigaPath', 'training-only optimized threshold', 'median_ba_delta_vs_empirical'), 3)} for Prov-GigaPath. AUROC and PR-AUC did not change across these three call rules because they used the same continuous outer scores."
)
doc.add_paragraph("Table 2. Catalogue-normalized breadth, sample-size maturity, binary operating-rule sensitivity and retention with complete TCGA tissue-source-site codes held apart. Crossings use Q²≥0.20 for continuous tasks and AUROC≥0.60 for binary tasks. The larger-sample stratum means n≥100 for continuous tasks or at least 50 patients per class for binary tasks. Macro rates are unweighted means of within-family or within-cancer crossing percentages. Counts are correlated task-level summaries, not independent discoveries.")
doc.add_paragraph("Panel A. Catalogue-normalized breadth.", style="Caption")
add_table(
    doc,
    ["Representation", "Outcome", "Inclusive crossings, n/N (%)", "Standard-evidence crossings, n/N (%)", "Unique definitions, n/N (%)", "Macro family rate", "Macro cancer rate"],
    [
        [display_representation(m), outcome,
         foundation_breadth_label(m, outcome), foundation_standard_label(m, outcome),
         foundation_definition_label(m, outcome),
         f"{foundation_breadth(m, outcome, 'macro_family_crossing_percent'):.1f}%",
         f"{foundation_breadth(m, outcome, 'macro_cancer_crossing_percent'):.1f}%"]
        for m in ("TITAN", "GigaSSL", "ProvGigaPath") for outcome in ("continuous", "binary")
    ],
    widths=[2.2, 1.5, 2.5, 2.7, 2.5, 2.0, 2.0],
    font_size=7.2, header_font_size=7.4, line_spacing=1.0,
)
doc.add_paragraph("Panel B. Cohort size, primary binary score metrics and grouped retention among primary crossings.", style="Caption")
add_table(
    doc,
    ["Representation", "Patients available / matched", "AUROC crossings", "Median PR-AUC", "Median no-skill PR-AUC", "Grouped retention continuous / binary"],
    [[display_representation(m), f"{ival(foundation_cohort_by_model[m]['patients']):,} / {foundation_common_n:,}",
      foundation_breadth_label(m, 'binary'),
      fnum(binary_operating_value(m, 'training-only optimized threshold', 'median_pr_auc'), 3),
      fnum(binary_operating_value(m, 'training-only optimized threshold', 'median_prevalence'), 3),
      f"{foundation_tss_retention(m, 'continuous')[0]}/{foundation_tss_retention(m, 'continuous')[1]} ({foundation_tss_retention_percent(m, 'continuous'):.1f}%) / {foundation_tss_retention(m, 'binary')[0]}/{foundation_tss_retention(m, 'binary')[1]} ({foundation_tss_retention_percent(m, 'binary'):.1f}%)"]
     for m in ("TITAN", "GigaSSL", "ProvGigaPath")],
    widths=[2.3, 2.5, 3.0, 3.0, 3.0, 3.5],
    font_size=7.2, header_font_size=7.4, line_spacing=1.0,
)
doc.add_paragraph("Panel B2. Atlas-wide operating-rule sensitivity on identical AUROC-selected scores.", style="Caption")
add_table(
    doc,
    ["Representation", "Empirical-prior median BA", "Equal-prior median BA", "Training-threshold median BA", "Median BA change, equal", "Median BA change, training threshold"],
    [[display_representation(m),
      fnum(binary_operating_value(m, 'empirical training priors', 'median_balanced_accuracy'), 3),
      fnum(binary_operating_value(m, 'equal class priors', 'median_balanced_accuracy'), 3),
      fnum(binary_operating_value(m, 'training-only optimized threshold', 'median_balanced_accuracy'), 3),
      fnum(binary_operating_value(m, 'equal class priors', 'median_ba_delta_vs_empirical'), 3),
      fnum(binary_operating_value(m, 'training-only optimized threshold', 'median_ba_delta_vs_empirical'), 3)]
     for m in ("TITAN", "GigaSSL", "ProvGigaPath")],
    widths=[2.4, 2.8, 2.8, 2.8, 3.2, 2.8],
    font_size=7.2, header_font_size=7.4, line_spacing=1.0,
)
doc.add_paragraph("Panel C. Provenance-stratified matched task crossings. Direct genomic alterations, derived phenotypes and same-H&E quantities are shown separately.", style="Caption")
provenance_panel_rows = [
    ("binary", "directly observed genomic alteration", "Direct genomic alterations"),
    ("binary", "composite genomic-context score", "Composite genomic-context status"),
    ("continuous", "sequencing-derived continuous burden", "Sequencing-derived burdens"),
    ("continuous", "computationally inferred immune-cell fraction", "Inferred immune-cell fractions"),
    ("continuous", "transcriptomic signature", "Transcriptomic signatures"),
    ("continuous", "composite genomic-context score", "Composite genomic-context scores"),
    ("continuous", "pathology-associated quantity", "Same-H&E TIL fraction"),
]
add_table(
    doc,
    ["Label class", "Outcome", "Eligible tasks", "TITAN crossings", "Giga-SSL crossings", "Prov-GigaPath crossings"],
    [[label, outcome, foundation_provenance_by_key[("TITAN", outcome, cls)]["eligible_tasks"],
      provenance_crossing_label("TITAN", outcome, cls),
      provenance_crossing_label("GigaSSL", outcome, cls),
      provenance_crossing_label("ProvGigaPath", outcome, cls)]
     for outcome, cls, label in provenance_panel_rows],
    widths=[4.0, 1.8, 1.9, 2.7, 2.7, 3.0],
    font_size=7.1, header_font_size=7.3, line_spacing=1.0,
)
doc.add_paragraph("Table 3. Provenance and technical scope of the released embedding pipelines used in the matched atlas. ‘Potential TCGA overlap’ refers to representation pretraining or development, not to downstream molecular-label fitting in this study.")
add_table(
    doc,
    ["Representation", "Pretraining / potential TCGA overlap", "Tile encoder", "Slide encoder / released layer", "Dimension and resolution", "Release identifier"],
    [
        ["TITAN", "Mass-340K (335,645 WSIs); TCGA excluded from pretraining but used in published downstream evaluation", "CONCH v1.5; 256-pixel patches", "TITAN slide encoder; official slide embedding", "768; patches at ×20, 8,192-pixel ROI views", "Official gated artifact; source hash in registry"],
        ["Giga-SSL", "Self-supervised gigapixel development used TCGA; direct slide overlap cannot be excluded", "ImageNet-pretrained ResNet-18 in released pipeline", "Sparse-convolutional MIL; TCGA_encoded_t5e1000", "512; pyramid level 1 in release, scanner-specific physical resolution not harmonised", "trislaz/gigassl 605b950"],
        ["Prov-GigaPath", "171,189 Providence WSIs; TCGA not reported as pretraining data", "DINOv2-style tile encoder", "LongNet slide encoder; final layer (13)", "768; 256-pixel tiles at 0.5 µm/pixel in reference pipeline", "seandavis/tcga_provgigapath_embeddings; source hash in registry"],
    ],
    widths=[2.1, 4.0, 2.7, 3.4, 3.4, 3.1],
)
add_figure(doc, "Figure2_foundation_model_breadth_effect.png", "Figure 2. Catalogue-normalized patient-level breadth and paired target-level effects for TITAN, Giga-SSL and Prov-GigaPath. Panel A reports task crossing rates, unique endpoint-definition coverage and unweighted macro-averages across endpoint families and cancers. Crossings use Q²≥0.20 for continuous cancer–endpoint pairs and AUROC≥0.60 for binary pairs after inner-AUROC component selection. Panel B shows the paired Q² and AUROC effects. Identical patients, outcomes, folds, seeds and tuning rules were used within each pair. Counts describe correlated tasks in this catalogue, not independent discoveries or representation-specific permutation/FDR results.")
add_figure(doc, "Figure3_foundation_model_consensus_retention.png", f"Figure 3. Cross-representation consensus and sensitivity to grouping by a barcode-derived cohort-structure variable. Panel A separates tasks retained by all three, by two or by one released representation. Panel B cross-tabulates the primary consensus class with retention for all {foundation_union_counts['tasks']} union-positive tasks after complete TCGA tissue-source-site codes were held apart; green means every originally crossing representation retained its performance threshold, orange that some retained it and red that none retained it. This is not institutional, scanner-level or external validation.")
doc.add_paragraph(
    f"Sensitivity to grouping by a barcode-derived cohort-structure variable materially changed the primary multi-representation priority map. All {foundation_union_counts['tasks']} union-positive tasks were evaluated for all three representations. Among all-three tasks, every primary crossing retained its threshold for {foundation_tss_consensus_counts[('continuous', 'all three', 'complete retention')]}/{foundation_all_three_counts['continuous']} continuous and {foundation_tss_consensus_counts[('binary', 'all three', 'complete retention')]}/{foundation_all_three_counts['binary']} binary pairs; retention was partial for {foundation_tss_consensus_counts[('continuous', 'all three', 'partial retention')]} and {foundation_tss_consensus_counts[('binary', 'all three', 'partial retention')]}, and absent for {foundation_tss_consensus_counts[('continuous', 'all three', 'no retention')]} and {foundation_tss_consensus_counts[('binary', 'all three', 'no retention')]}. Representation-level retention ranged from {min(foundation_tss_retention_percent(m, 'continuous') for m in ('TITAN', 'GigaSSL', 'ProvGigaPath')):.1f}% to {max(foundation_tss_retention_percent(m, 'continuous') for m in ('TITAN', 'GigaSSL', 'ProvGigaPath')):.1f}% for continuous crossings and from {min(foundation_tss_retention_percent(m, 'binary') for m in ('TITAN', 'GigaSSL', 'ProvGigaPath')):.1f}% to {max(foundation_tss_retention_percent(m, 'binary') for m in ('TITAN', 'GigaSSL', 'ProvGigaPath')):.1f}% for binary crossings. These estimates remain internal TCGA sensitivity analyses and do not establish generalisability."
)
doc.add_paragraph(
    f"Grouped-fold adequacy was heterogeneous despite computational feasibility. Outer test sets in the common-cohort audit ranged from {min(float(foundation_tss_adequacy_by_outcome[o]['minimum_outer_test_n']) for o in ('binary', 'continuous')):.0f} to {max(float(foundation_tss_adequacy_by_outcome[o]['maximum_outer_test_n']) for o in ('binary', 'continuous')):.0f} patients. The descriptive sparse-fold flag was triggered for {foundation_tss_adequacy_by_outcome['binary']['tasks_with_sparse_grouped_folds']}/{foundation_tss_adequacy_by_outcome['binary']['tasks']} binary and {foundation_tss_adequacy_by_outcome['continuous']['tasks_with_sparse_grouped_folds']}/{foundation_tss_adequacy_by_outcome['continuous']['tasks']} continuous tasks. The machine-readable fold audit reports realized fold counts, code counts, test-set sizes, class counts and single-class indicators for every task. The flag is an audit warning rather than an exclusion or validity threshold."
)
doc.add_paragraph(
    "Matched-random controls separated changes associated with grouped fold size and class balance from additional changes associated with holding complete tissue-source-site codes apart. The target-level table reports grouped Q² or AUROC, its matched-random counterpart and the paired difference for every representation. Several strong random-fold associations attenuated materially, so multi-representation consensus does not itself demonstrate robustness to cohort structure and the grouped estimate remains cohort- and partition-dependent."
)
add_figure(doc, "Figure6_site_grouped_sensitivity.png", f"Figure 4. Central cohort-structure sensitivity in the deeply audited TITAN layer. Panel A compares all {len(site_c) + len(site_b)} random-fold estimates with estimates obtained when complete TCGA tissue-source-site codes were held apart; Panel B shows the six largest attenuations; Panel C shows the 10 strongest chance-normalized code-classification results. The code is not an institution, scanner or laboratory identifier, and attenuation does not by itself establish technical confounding.")
if foundation_fold_summary and foundation_winner_stability:
    winner_c = winner_stability("continuous")
    winner_b = winner_stability("binary")
    doc.add_paragraph(
        "Fold-assignment stability was examined in five new matched nested partitions for the fixed 560-task union-positive or near-threshold set (322 continuous; 238 binary). Among primary crossings, all five alternative partitions retained the threshold for "
        + "; ".join(
            f"{display_representation(model)} {outcome} {stable_primary_crossings(model, outcome)[0]}/{stable_primary_crossings(model, outcome)[1]}"
            for outcome in ("continuous", "binary")
            for model in ("TITAN", "ProvGigaPath", "GigaSSL")
        )
        + ". The primary all-three consensus class persisted in every alternative partition for "
        f"{consensus_class_stability('continuous', ['all three'])[0]}/{consensus_class_stability('continuous', ['all three'])[1]} continuous and "
        f"{consensus_class_stability('binary', ['all three'])[0]}/{consensus_class_stability('binary', ['all three'])[1]} binary pairs. In contrast, exactly-two or representation-specific status persisted in all five for only "
        f"{consensus_class_stability('continuous', ['exactly two', 'representation specific'])[0]}/{consensus_class_stability('continuous', ['exactly two', 'representation specific'])[1]} continuous and "
        f"{consensus_class_stability('binary', ['exactly two', 'representation specific'])[0]}/{consensus_class_stability('binary', ['exactly two', 'representation specific'])[1]} binary pairs. The primary leading representation was unchanged in all five partitions for "
        f"{winner_c['all_five']}/{winner_c['tasks']} continuous and {winner_b['all_five']}/{winner_b['tasks']} binary pairs, and in a majority for {winner_c['majority']}/{winner_c['tasks']} and {winner_b['majority']}/{winner_b['tasks']}. "
        f"Threshold curves showed the expected categorical sensitivity: for TITAN, mean selected-set crossings ranged from {threshold_mean_crossings('TITAN', 'continuous', 0.10):.1f} at Q²≥0.10 to {threshold_mean_crossings('TITAN', 'continuous', 0.30):.1f} at Q²≥0.30 and from {threshold_mean_crossings('TITAN', 'binary', 0.55):.1f} at balanced accuracy≥0.55 to {threshold_mean_crossings('TITAN', 'binary', 0.65):.1f} at ≥0.65. Continuous paired effects, repeat ranks and all threshold curves are therefore reported alongside, not replaced by, the categorical consensus labels (Table S15g; Figure S3)."
    )
doc.add_paragraph("Table 4. Paired representation effects relative to TITAN under the specified PLS/PLS–LDA probe. Δ is alternative representation minus TITAN; uncertainty is a descriptive 95% cancer-cluster bootstrap interval for the median paired task difference.")
add_table(
    doc,
    ["Comparison", "Outcome", "Alternative/TITAN wins", "Ties", "Median Δ (95% interval)", "Spearman"],
    [[r["comparison"].replace("GigaSSL", "Giga-SSL").replace("ProvGigaPath", "Prov-GigaPath"), r["outcome_type"], f"{r['other_higher']}/{r['TITAN_higher']}", r["tied"],
      f"{fnum(r['median_delta_vs_TITAN'], 3)} ({fnum(r['cluster_bootstrap_low'], 3)} to {fnum(r['cluster_bootstrap_high'], 3)})",
      fnum(r["spearman_effect"], 3)] for r in foundation_pairwise],
    widths=[3.4, 2.0, 3.0, 1.3, 4.3, 1.8],
)
if titan_prov_paired_by_outcome:
    tp_cont = titan_prov_paired_by_outcome["continuous"]
    tp_bin = titan_prov_paired_by_outcome["binary"]
    doc.add_paragraph(
        "A separate paired summary was retained for TITAN and Prov-GigaPath because their reported pretraining corpora did not include TCGA. "
        f"For continuous pairs, both crossed the effect threshold in {ival(tp_cont['both_effect_threshold_crossing']):,}/1,507 tasks, TITAN alone in {ival(tp_cont['TITAN_only_crossing']):,}, Prov-GigaPath alone in {ival(tp_cont['ProvGigaPath_only_crossing']):,} and neither in {ival(tp_cont['neither_crossing']):,}; TITAN had the higher target-level effect in {ival(tp_cont['TITAN_higher_effect']):,} tasks and Prov-GigaPath in {ival(tp_cont['ProvGigaPath_higher_effect']):,} (median Prov-GigaPath minus TITAN ΔQ² {fnum(tp_cont['median_delta_ProvGigaPath_minus_TITAN'], 3)}, 95% cancer-cluster bootstrap interval {fnum(tp_cont['cluster_bootstrap_low'], 3)} to {fnum(tp_cont['cluster_bootstrap_high'], 3)}). "
        f"For binary pairs, both crossed in {ival(tp_bin['both_effect_threshold_crossing']):,}/426 tasks, TITAN alone in {ival(tp_bin['TITAN_only_crossing']):,}, Prov-GigaPath alone in {ival(tp_bin['ProvGigaPath_only_crossing']):,} and neither in {ival(tp_bin['neither_crossing']):,}; TITAN had the higher effect in {ival(tp_bin['TITAN_higher_effect']):,} tasks and Prov-GigaPath in {ival(tp_bin['ProvGigaPath_higher_effect']):,} (median Δ {fnum(tp_bin['median_delta_ProvGigaPath_minus_TITAN'], 3)}, {fnum(tp_bin['cluster_bootstrap_low'], 3)} to {fnum(tp_bin['cluster_bootstrap_high'], 3)}). "
        "This narrower summary reduces one known difference in reported pretraining exposure but remains a comparison of two complete released pipelines, not external validation or an isolated test of model architecture."
    )
if translational_consensus and translational_consensus_examples:
    all_three_rows = [r for r in translational_consensus if ival(r.get("n_representations_retained")) == 3]
    exactly_two_rows = [r for r in translational_consensus if ival(r.get("n_representations_retained")) == 2]
    unique_rows = [r for r in translational_consensus if ival(r.get("n_representations_retained")) == 1]
    thorsson_union = [r for r in translational_consensus if r.get("family") == "thorsson" and ival(r.get("n_representations_retained")) > 0]
    mutation_union = [r for r in translational_consensus if r.get("family") == "driver_mutation" and ival(r.get("n_representations_retained")) > 0]
    doc.add_paragraph(
        f"Cross-representation consensus was observed for {len(all_three_rows)} tasks (87 continuous and 43 binary); {len(exactly_two_rows)} were retained by exactly two representations and {len(unique_rows)} were representation-specific. Under the matched three-representation grouped analysis, complete retention of every original crossing occurred for {foundation_tss_consensus_counts[('continuous', 'all three', 'complete retention')]}/87 continuous and {foundation_tss_consensus_counts[('binary', 'all three', 'complete retention')]}/43 binary all-three tasks; therefore consensus alone was not treated as evidence of cohort-structure robustness. Consensus was similar in proportional terms for derived Thorsson immune/genomic-context outcomes ({sum(ival(r.get('n_representations_retained')) == 3 for r in thorsson_union)}/{len(thorsson_union)}, {100*sum(ival(r.get('n_representations_retained')) == 3 for r in thorsson_union)/len(thorsson_union):.1f}%) and directly observed driver mutations ({sum(ival(r.get('n_representations_retained')) == 3 for r in mutation_union)}/{len(mutation_union)}, {100*sum(ival(r.get('n_representations_retained')) == 3 for r in mutation_union)/len(mutation_union):.1f}%), although immune outcomes dominated the absolute number of consensus tasks. Fusion associations were less concordant (1/10 union-positive tasks retained by all three)."
    )
    def effect_triplet(r):
        if r["outcome_type"] == "binary":
            values = []
            for model in ("TITAN", "GigaSSL", "ProvGigaPath"):
                z = foundation_matched_by_key[(model, r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"])]
                values.append(f"{fnum(z.get('balanced_accuracy'), 3)} ({fnum(z.get('auc'), 3)})")
            return " / ".join(values)
        return f"{fnum(r.get('effect_TITAN'), 3)} / {fnum(r.get('effect_GigaSSL'), 3)} / {fnum(r.get('effect_ProvGigaPath'), 3)}"
    def repeat_crossing_triplet(r):
        values = []
        for model in ("TITAN", "GigaSSL", "ProvGigaPath"):
            z = foundation_crossing_task_map.get((r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"], model), {})
            values.append(fnum(z.get("crossing_proportion"), 1))
        return " / ".join(values)
    def grouped_triplet(r):
        return " / ".join(fnum(r.get(f"matched_grouped_metric_{model}"), 3)
                          for model in ("TITAN", "GigaSSL", "ProvGigaPath"))
    doc.add_paragraph("Table 5. Translational consensus, grouped retention and internal robustness examples. Effects are Q² for continuous tasks and empirical-prior PLS–LDA balanced accuracy with secondary AUROC in parentheses for binary tasks. Values after the semicolon are the proportions of five alternative partitions crossing Q²≥0.20 or balanced accuracy≥0.60. The grouped column reports Q² for continuous tasks or balanced accuracy for binary tasks after complete TCGA tissue-source-site codes were held apart on the same common cohort. R1–R4 jointly encode representation consensus, sample-size maturity and grouped retention; they are internal prioritisation classes, not clinical grades. The complete 1,933-task audit and all 340 grouped task results are machine-readable.")
    add_table(
        doc,
        ["Target (type)", "Consensus class", "Q² or BA (AUROC); five-repeat crossing proportions T/G/P", "Grouped Q²/BA T/G/P", "Internal robustness class"],
        [[f"{r['tumor_type']}–{r['endpoint']} [{families.get(r['family'], r['family'])}] ({r['outcome_type']})", r["consensus_class"], f"{effect_triplet(r)}; {repeat_crossing_triplet(r)}", grouped_triplet(r), r["internal_robustness_class"].split(":")[0]]
         for r in translational_consensus_examples],
        widths=[4.0, 2.7, 4.3, 2.8, 4.4],
    )
if foundation_family_summary and foundation_cancer_summary:
    top_family = {}
    top_cancer = {}
    for model in ("TITAN", "GigaSSL", "ProvGigaPath"):
        for outcome in ("continuous", "binary"):
            fam = [r for r in foundation_family_summary if r["foundation_model"] == model and r["outcome_type"] == outcome]
            can = [r for r in foundation_cancer_summary if r["foundation_model"] == model and r["outcome_type"] == outcome]
            top_family[(model, outcome)] = max(fam, key=lambda r: ival(r["effect_threshold_crossings"]))
            top_cancer[(model, outcome)] = max(can, key=lambda r: ival(r["effect_threshold_crossings"]))
    doc.add_paragraph(
        "The normalized summaries preserved the overall ordering but showed how strongly it depended on catalogue composition. Unweighted macro family crossing rates were 7.6%/63.0% for TITAN, 5.5%/43.0% for Prov-GigaPath and 2.9%/37.0% for Giga-SSL (continuous/binary); corresponding macro cancer rates were 13.6%/26.5%, 8.5%/25.4% and 6.9%/22.9%. The comparison was also stratified by endpoint family and cancer. "
        + " Family-level leading crossing counts were "
        + "; ".join(
            f"{display_representation(m)} {o}: {top_family[(m,o)]['family']} ({top_family[(m,o)]['effect_threshold_crossings']})"
            for m in ("TITAN", "GigaSSL", "ProvGigaPath") for o in ("continuous", "binary")
        )
        + ". Cancer-level leading counts were "
        + "; ".join(
            f"{display_representation(m)} {o}: {top_cancer[(m,o)]['tumor_type']} ({top_cancer[(m,o)]['effect_threshold_crossings']})"
            for m in ("TITAN", "GigaSSL", "ProvGigaPath") for o in ("continuous", "binary")
        )
        + ". Supplementary Table S17 reports normalized breadth, leading strata and the endpoint definitions and biological programmes retained across the most cancers; machine-readable companions retain every stratum and cancer code."
    )
if foundation_probe_summary:
    probe_by_type = {r["outcome_type"]: r for r in foundation_probe_summary}
    doc.add_heading("Sensitivity to downstream algorithm and component range", level=2)
    doc.add_paragraph(
        "This retrospective sensitivity tested the three-representation ordering on the same fixed 47-target metadata-stratified subset used for the symmetric PLS–ridge benchmark. It is representative but not atlas-wide. Ridge Gaussian or logistic models used the same patients and target-specific folds across representations; AUROC was used for binary representation ranking and Q² for continuous ranking. The identity of the best representation was retained after replacing PLS/PLS–LDA with ridge for "
        f"{ival(probe_by_type['binary']['winner_retained'])}/{ival(probe_by_type['binary']['targets'])} binary targets ({fnum(probe_by_type['binary']['winner_retained_percent'], 1)}%) and "
        f"{ival(probe_by_type['continuous']['winner_retained'])}/{ival(probe_by_type['continuous']['targets'])} continuous targets ({fnum(probe_by_type['continuous']['winner_retained_percent'], 1)}%). "
        "Thus, target-level representation ranking was materially probe-dependent even though aggregate tendencies could remain similar. This subset sensitivity supports reporting representation–probe pairs and precludes an intrinsic foundation-model superiority claim; it does not estimate how often an atlas-wide ridge analysis would change the ordering."
    )
if foundation_component_audit and foundation_variance_audit:
    doc.add_paragraph(
        "Across the complete 1,933-task matched atlas with the fixed 1–10 PLS range, at least one of the five outer fits reached the ten-component ceiling for "
        + "; ".join(
            f"{r['foundation_model']} {r['outcome_type']} {r['targets_with_any_outer_fit_at_ceiling']}/{r['targets']} targets ({fnum(r['target_ceiling_percent'], 1)}%)"
            for r in foundation_component_audit
        )
        + ". The target-level ceiling frequency was therefore substantial for binary tasks but low for continuous tasks. No numerical fallback was invoked in the completed atlas. Global feature-variance auditing found no constant dimensions for TITAN or Prov-GigaPath and five constant dimensions for Giga-SSL. They were retained to preserve the released 512-feature schema; training-fold centering maps each constant column to zero, so it cannot alter covariance, latent scores, effective rank or effective component counts. Fold-level ceiling counts, component distributions and the expanded-component sensitivity are reported in the Supplement."
    )
if foundation_component_range and foundation_component_winners:
    doc.add_paragraph(
        "Expanding the component range from 1–10 to 1–20 on the same 47-target subset did not produce a uniform performance gain: median changes ranged from −0.017 to 0.013 across representation–outcome strata. The best representation was retained for "
        f"{foundation_component_winner_summary['binary']['retained']}/{foundation_component_winner_summary['binary']['targets']} binary and {foundation_component_winner_summary['continuous']['retained']}/{foundation_component_winner_summary['continuous']['targets']} continuous targets; 22/35 binary and 3/12 continuous winners changed. "
        "Accordingly, both the downstream algorithm and the permitted latent dimensionality can alter target-level rankings. Because this wider-range analysis is restricted to 47 targets, the primary article is explicitly a fixed 1–10-component PLS-based benchmark rather than a comparison of best-achievable pipeline performance."
    )
if foundation_slide_audit and foundation_exact_slide_sensitivity:
    doc.add_heading("Exact-common-slide sensitivity", level=2)
    doc.add_paragraph(
        f"Exact slide sets were identical for {ival(foundation_slide_audit.get('identical_slide_set_patients')):,}/{ival(foundation_slide_audit.get('common_patients')):,} patients ({fnum(foundation_slide_audit.get('identical_slide_set_percent'), 2)}%). The remaining {ival(foundation_slide_audit.get('patients_with_any_slide_set_difference'))} patients had a within-patient slide-count range of one in 20 patients, two in 9, three in 3 and four in 2. No patient was lost after restricting every representation to the {ival(foundation_slide_audit.get('exact_common_slides')):,} exactly shared slides."
    )
    doc.add_paragraph(
        "Repeating all 1,933 cancer–endpoint tasks after exact-slide restriction left median performance changes at zero or effectively zero in every representation and outcome stratum. Individual near-threshold entries could change membership, so Table 6 and the machine-readable sensitivity table retain both estimates. The aggregate ordering and conclusion were unchanged, but the primary common-patient comparison is interpreted as representation-associated rather than a perfectly isolated representation effect."
    )
    doc.add_paragraph("Table 6. Exact-common-slide sensitivity of the multi-foundation-model atlas.")
    add_table(
        doc,
        ["Representation", "Outcome", "Primary positive", "Exact-slide positive", "Median Δ", "Spearman"],
        [[display_representation(r["foundation_model"]), r["outcome_type"], r["primary_screening_positive"],
          r["exact_screening_positive"], fnum(r["median_delta"], 4),
          fnum(r["spearman_primary_exact"], 3)] for r in foundation_exact_slide_sensitivity],
        widths=[2.6, 2.1, 2.3, 2.6, 1.8, 1.8],
    )
doc.add_heading("Secondary layer: inferentially qualified TITAN screen", level=2)
doc.add_paragraph(
    f"This separate layer used the larger {n_patients:,}-patient TITAN cohort and evaluated {len(continuous) + len(binary):,} eligible cancer–endpoint pairs ({len(continuous):,} continuous; {len(binary):,} binary). Of these, {titan_candidate_total} met both the outcome-specific effect threshold and the empirical-permutation/FDR rules documented in the initial repository snapshot. Only these {titan_candidate_total} entered the five additional nested-validation repeats and sensitivity analysis grouped by TCGA tissue-source-site code. These inferential qualifications apply to TITAN only and do not convert the primary three-representation crossing counts into multiplicity-controlled discoveries."
)
doc.add_heading("Sex- and broad race-stratified performance audit", level=2)
doc.add_paragraph(
    f"Of {titan_candidate_total} screen-positive models, {len(subgroup_high_volume_models)} had at least 200 outcome-labelled patients. "
    f"Using fixed repeated out-of-fold predictions, both recorded-sex groups met the minimum denominator fixed for this post hoc subgroup audit in "
    f"{subgroup_two_group_models['continuous_sex']} continuous and {subgroup_two_group_models['binary_sex']} binary models; "
    f"at least two broad race groups were estimable in {subgroup_two_group_models['continuous_race']} continuous and "
    f"{subgroup_two_group_models['binary_race']} binary models. The complete audit contains {len(subgroup_performance):,} "
    f"model–subgroup rows, including exact subgroup and binary class counts, {len(subgroup_estimable_rows):,} estimable "
    f"performance rows and a specific non-estimability reason for every remaining row. Across estimable female–male comparisons, "
    f"the median absolute difference was {fnum(subgroup_contrast[('Female versus male', 'continuous')].get('median_absolute_difference'))} in Q², "
    f"{fnum(subgroup_contrast[('Female versus male', 'binary')].get('median_absolute_difference'))} in AUROC and "
    f"{fnum(subgroup_contrast[('Female versus male', 'binary')].get('median_absolute_balanced_accuracy_difference'))} in balanced accuracy. "
    f"For White versus each estimable non-White category, the corresponding medians were "
    f"{fnum(subgroup_contrast[('White versus each estimable non-White category', 'continuous')].get('median_absolute_difference'))} in Q², "
    f"{fnum(subgroup_contrast[('White versus each estimable non-White category', 'binary')].get('median_absolute_difference'))} in AUROC and "
    f"{fnum(subgroup_contrast[('White versus each estimable non-White category', 'binary')].get('median_absolute_balanced_accuracy_difference'))} in balanced accuracy. "
    "These are descriptive, post hoc "
    "internal TCGA estimates from the same held-out predictions—not independently validated fairness estimates—and small "
    "differences should not be interpreted as evidence of demographic equivalence or disparity."
)
doc.add_heading("Endpoint provenance and assay equivalence", level=2)
doc.add_paragraph(
    f"The target-level audit classified the {len(endpoint_dictionary):,} eligible tests as "
    f"{endpoint_class_result_text}. These categories describe the label-generation modality, "
    "not the modality of the TITAN predictor. Only the 13 cancer-specific TIL Regional Fraction "
    "tests used an outcome derived from H&E itself. Thus, apparent predictability of CIBERSORT "
    "fractions, leukocyte fraction or RNA signatures is agreement with another computational "
    "phenotype and cannot be interpreted as recovery of a directly measured immune-cell count. "
    "The complete target-level dictionary and the 194-definition dictionary are Supplementary "
    "Table S13 machine-readable companions."
)

doc.add_heading("Continuous derived immune, genomic-context and instability phenotypes", level=2)
doc.add_paragraph(f"Among continuous targets, {len([r for r in supported_c if r['tier']=='A'])} were assigned to screening tier A and {len([r for r in supported_c if r['tier']=='B'])} to tier B. The largest primary screening Q² values were {examples(top_c, 'q2', 10)}. These initial nested-CV values determined screening and tier assignment; five-repeat means are reported separately for stability. These cross-validated statistical associations were cancer specific: the same endpoint could meet the predictability criterion in one tumour type and be screen-negative in another. This contrast is predictive, not evidence of a cancer-specific causal mechanism.")
doc.add_paragraph("As an explicit example of the two reporting stages, THYM–Th17 had primary screening Q²=0.638 and a five-repeat mean repeated-validation Q²=0.594. This difference reflects independently seeded nested-CV partitions and is not a discrepancy or a change to the primary screen result.")
doc.add_paragraph(f"Of {len(supported_c)} within-cancer screen-positive continuous pairs, {len(global_supported_c)} met q<0.05 under the stricter across-cancer family sensitivity after the 999-permutation refinement. " + ("Continuous findings should therefore be interpreted as cancer-specific candidates rather than globally FDR-supported pan-cancer discoveries. Because the minimum completed-test p-value was 0.001, the global sensitivity was resolution-limited for large endpoint families; failure to pass it is not evidence of absence of biological signal." if not global_supported_c else "Pairs passing this sensitivity are identified explicitly in the figure and machine-readable table; the remainder are cancer-specific candidates. The 0.001 minimum completed-test p-value should be considered when interpreting large global families."))
add_figure(doc, "Figure2_continuous_atlas.png", "Figure 5. Deeply audited TITAN atlas layer: 12 strongest within-cancer screen-positive continuous cancer–endpoint results, ranked by primary screening Q². The complete three-representation atlas is reported in Table 2, Figures 2–3, Supplementary Table S15 and machine-readable files. All Q² values use genuine patient-level outer-fold predictions.")

doc.add_heading("Continuous sample-size and development reliability", level=2)
doc.add_paragraph(
    f"The {len(continuous_reliability)} continuous candidates had 61–1,051 outcome-labelled patients (median 371; interquartile range 233.5–468); {len(continuous_limited_reliability)} had fewer than 100. In this limited group, median five-repeat Q² was 0.213, median across-repeat Q² standard deviation was 0.054 and median pairwise repeat-prediction Spearman correlation was 0.892. Corresponding values among the {len(continuous_standard)} models with at least 100 patients were 0.301, 0.017 and 0.936. Sample size had little monotonic association with mean Q² (Spearman ρ=0.060) but a moderate positive association with repeat-prediction stability (ρ=0.367)."
)
doc.add_paragraph(
    f"Across all {len(continuous_components):,} repeated outer fits, {sum(ival(r.get('outer_fits_at_ceiling')) for r in continuous_reliability)}/5,475 (0.7%) selected the ten-component ceiling; {sum(str(r.get('any_outer_fit_at_ceiling')).upper() == 'TRUE' for r in continuous_reliability)}/{len(continuous_reliability)} models reached it at least once. The limited group accounted for 3/325 ceiling selections and 2/13 models reaching the ceiling. These descriptive differences do not show that sample size caused instability, but they support a visible evidence warning. All 13 models remain in the atlas and registry, are excluded from default PathoFMPred inference, and require explicit opt-in. Endpoint-level results and sample-size bands are in Supplementary Table S10h and Figure S2."
)

doc.add_heading("Binary molecular phenotypes", level=2)
doc.add_paragraph(f"The binary screen yielded {len([r for r in supported_b if r['tier']=='A'])} candidates in screening tier A and {len([r for r in supported_b if r['tier']=='B'])} in tier B. The largest primary screening balanced accuracies were {examples(top_b, 'balanced_accuracy', 12, include_family=True)}. These initial nested-CV values determined screening and tier assignment; five-repeat means are reported separately for stability. The complete table distinguishes tested-negative pairs from outcomes that failed prevalence or sample-size eligibility.")
doc.add_paragraph(f"Of {len(supported_b)} within-cancer screen-positive binary pairs, {len(global_supported_b)} also met the stricter across-cancer family q<0.05, including {len(global_mutation_b)} cancer–gene mutation pairs. " + ("Mutation results are consequently cancer-specific discovery candidates, even where their within-cancer discrimination was strong. The 0.001 permutation resolution also limits the attainable across-cancer q-value for a mutation family spanning many cancer–gene tests." if not global_mutation_b else "Mutation pairs passing this stricter sensitivity are distinguished from those supported only within cancer; the 0.001 permutation resolution remains relevant for the full mutation family."))
if binary_decision_all:
    titan_rule = binary_decision_summary_by_key.get(
        ("TITAN permutation/FDR screen", "TITAN", "all eligible"), {}
    )
    matched_rule_text = []
    for model in ("TITAN", "GigaSSL", "ProvGigaPath"):
        r = binary_decision_summary_by_key.get(
            ("matched three-representation atlas", model, "all eligible"), {}
        )
        if r:
            matched_rule_text.append(
                f"{display_representation(model)} {ival(r.get('baseline_empirical_prior_crossings'))}/"
                f"{ival(r.get('equal_prior_crossings'))}/{ival(r.get('optimized_crossings'))}"
            )
    doc.add_paragraph(
        "The revision-added complete decision-rule audit showed that binary threshold crossings were not invariant to "
        "the operating rule. In the 459-pair TITAN inferential-screen universe, empirical-prior/equal-prior/"
        f"inner-optimized rules produced {ival(titan_rule.get('baseline_empirical_prior_crossings'))}/"
        f"{ival(titan_rule.get('equal_prior_crossings'))}/{ival(titan_rule.get('optimized_crossings'))} effect-threshold "
        f"crossings; the optimized rule retained {ival(titan_rule.get('baseline_retained_optimized'))}, lost "
        f"{ival(titan_rule.get('baseline_lost_optimized'))} and gained {ival(titan_rule.get('optimized_gained'))} relative "
        f"to the empirical-prior rule. Of the {len(titan_optimized_gains)} optimized-rule gains, {titan_optimized_gains_limited} ({100 * titan_optimized_gains_limited / max(1, len(titan_optimized_gains)):.1f}%) had fewer than 50 patients in the minority class; limited-class models comprised {titan_optimized_crossing_limited}/{ival(titan_rule.get('optimized_crossings'))} optimized crossings versus {titan_empirical_crossing_limited}/{ival(titan_rule.get('baseline_empirical_prior_crossings'))} empirical-prior crossings. In the matched 426-pair atlas, the corresponding empirical/equal/optimized "
        f"counts were {'; '.join(matched_rule_text)}. These are operating-rule sensitivities, not alternative "
        "permutation/FDR-qualified candidate sets: a gained threshold crossing was not promoted to a TITAN candidate "
        "without repeating the complete permutation procedure under that rule. AUROC and PR-AUC were unchanged by "
        "threshold placement for a fixed fitted score but could differ when the inner objective selected another "
        "component count. Complete membership changes and fold-specific selected components and thresholds are in "
        "Supplementary Table S10i and the machine-readable companions."
    )
doc.add_heading("Binary class-size sensitivity and development stability", level=2)
doc.add_paragraph(
    f"Of {ival(binary_sensitivity_20.get('eligible_binary_targets'))} binary pairs eligible at 20 patients per class, "
    f"{ival(binary_sensitivity_50.get('eligible_binary_targets'))} ({fnum(binary_sensitivity_50.get('eligible_target_retention_percent'), 1)}%) "
    f"also met a 50-per-class rule. Among the {len(supported_b)} screen-positive models, "
    f"{len(binary_standard)} ({100 * len(binary_standard) / max(1, len(supported_b)):.1f}%) met that stricter standard. "
    f"The other {len(binary_limited_reliability)} were designated exploratory/limited evidence; none of the highlighted "
    "binary models was in this group. The complete atlas retains these results for transparency, whereas default "
    f"the default PathoFMPred TITAN interface now includes {len(binary_standard)} binary and {len(continuous_standard)} continuous models and omits "
    "both limited-evidence subsets unless explicitly requested."
)
doc.add_paragraph(
    f"Across all {len(supported_b)} screen-positive binary models, the smallest repeated outer test fold contained "
    f"{binary_min_outer_positive} positive and {binary_min_outer_negative} negative patients. Within the limited subset, "
    f"exact reconstructed inner folds contained as few as {limited_min_inner_training_positive} positive and "
    f"{limited_min_inner_training_negative} negative training patients and {limited_min_inner_validation_positive} positive and "
    f"{limited_min_inner_validation_negative} negative validation patients. Selected components were therefore reported "
    f"for every one of the 25 repeated outer fits: {sum(ival(r.get('selected_components_minimum')) == 1 for r in binary_limited_reliability)}/{len(binary_limited_reliability)} limited models selected one component in at least one fit, "
    f"{sum(ival(r.get('selected_components_maximum')) == 10 for r in binary_limited_reliability)}/{len(binary_limited_reliability)} reached the ten-component ceiling, and "
    f"{sum(ival(r.get('selected_components_minimum')) == 1 and ival(r.get('selected_components_maximum')) == 10 for r in binary_limited_reliability)} spanned both extremes."
)
doc.add_paragraph(
    f"For the {len(binary_limited_reliability)} limited models, median learning-curve balanced accuracy was "
    f"{fnum(binary_learning_50.get('balanced_accuracy'))}, {fnum(binary_learning_75.get('balanced_accuracy'))} and "
    f"{fnum(binary_learning_100.get('balanced_accuracy'))} at 50%, 75% and 100% of the outer-training data; median AUROC was "
    f"{fnum(binary_learning_50.get('auc'))}, {fnum(binary_learning_75.get('auc'))} and {fnum(binary_learning_100.get('auc'))}, "
    f"and median PR-AUC was {fnum(binary_learning_50.get('pr_auc'))}, {fnum(binary_learning_75.get('pr_auc'))} and "
    f"{fnum(binary_learning_100.get('pr_auc'))}. Median repeat score correlation was "
    f"{fnum(median(r.get('repeat_score_spearman_mean') for r in binary_limited_reliability))} in the limited subset versus "
    f"{fnum(median(r.get('repeat_score_spearman_mean') for r in binary_standard))} in the ≥50-per-class subset. "
    "Class-call agreement was also reported, but can appear high under marked imbalance and is not interpreted alone. "
    "Endpoint-level PR-AUC, TCGA-prevalence PPV/NPV, fold counts, component distributions, learning curves and stability "
    "are provided in Supplementary Table S10g and Figure S1."
)
doc.add_heading("Permutation resolution and atlas-wide multiplicity sensitivity", level=2)
doc.add_paragraph(
    "The p-value audit separates models that were never permuted from models censored during permutation. Among 1,614 eligible continuous tests, 1,393 were below the Q² checkpoint and received raw p=1 without permutation; 221 completed 999 permutations. Among 459 eligible binary tests, 352 were below the balanced-accuracy checkpoint and received raw p=1 without permutation; 104 completed 999 permutations; and three entered permutation testing but were conservatively early-stopped after 49 exceedances and separately labelled raw p=1. Every one of the 2,073 eligible rows was retained in its local, across-cancer/family, outcome-wide and atlas-wide BH denominator. The machine-readable audit reproduces the saved q-values exactly."
)
doc.add_paragraph(
    f"The primary within-cancer/family procedure identified {ival(combined_multiplicity.get('within_cancer_family_candidates'))} candidates. "
    f"Of these, {ival(combined_multiplicity.get('across_cancer_family_pass'))} passed BH within outcome type and endpoint family across cancers, "
    f"{ival(combined_multiplicity.get('outcome_wide_pass'))} passed BH across all eligible tests within their outcome type, and "
    f"{ival(combined_multiplicity.get('atlas_wide_pass'))} passed one BH correction across all {ival(combined_multiplicity.get('eligible_tests')):,} eligible continuous and binary atlas tests. "
    "The three local candidates not retaining atlas-wide q<0.05 were READ genome doubling, OV–TP53 mutation and SKCM–BRAF mutation. "
    "The candidate count should therefore be read as a collection of locally controlled cancer-specific questions, with the atlas-wide result as a stricter sensitivity—not as if the primary procedure were one global 5% FDR analysis."
)
doc.add_paragraph(
    f"Among completed 999-permutation tests, {len(zero_999)} had zero null statistics at least as extreme as observed. Their finite empirical p-value was 0.001, but the exact two-sided 95% Monte Carlo interval for the underlying exceedance probability was 0–{fnum(zero_999_upper, 6)}. "
    f"The separately locked high-resolution subset extended {len(targeted_permutation)} leading models to 9,999 full nested permutations; {len(targeted_zero)} had zero exceedances and refined p-values were {targeted_p_summary}. "
    "The refined values are a targeted precision sensitivity and were not inserted into the primary FDR calculations. Because many primary p- and q-values remain tied at their attainable minimum, figures and tables are ordered by the outcome-appropriate predictive metric, with repeated stability and stability under grouping by TCGA tissue-source-site code reported alongside; q-values are not used for ranking."
)
add_figure(doc, "Figure3_binary_atlas.png", "Figure 6. Deeply audited TITAN atlas layer: 12 strongest within-cancer screen-positive binary genomic-alteration or derived genomic-context associations among the 87 models with at least 50 patients per class, ranked by primary screening balanced accuracy. Each plotted label reports balanced accuracy, AUROC, PR-AUC and observed TCGA prevalence; prevalence is the no-skill PR-AUC reference. Complete three-representation results are supplied in Supplementary Table S15 and machine-readable files; the 17 limited-evidence TITAN models appear in Figure S1.")
doc.add_paragraph(
    f"Precision–recall performance was reported for every screen-positive binary endpoint. Across all {len(binary_reliability)} models, "
    f"median five-repeat PR-AUC was {fnum(median(r.get('repeated_pr_auc_mean') for r in binary_reliability))}; each value should be read against its no-skill reference, the observed TCGA prevalence. "
    f"The {len(low_prevalence_mutation_fusion)} mutation or fusion endpoints with prevalence below 0.20 had median prevalence "
    f"{fnum(median(r.get('observed_tcga_prevalence') for r in low_prevalence_mutation_fusion))}, median PR-AUC "
    f"{fnum(median(r.get('repeated_pr_auc_mean') for r in low_prevalence_mutation_fusion))} (range "
    f"{fnum(min(float(r.get('repeated_pr_auc_mean')) for r in low_prevalence_mutation_fusion))}–"
    f"{fnum(max(float(r.get('repeated_pr_auc_mean')) for r in low_prevalence_mutation_fusion))}), despite median AUROC "
    f"{fnum(median(r.get('repeated_auc_mean') for r in low_prevalence_mutation_fusion))}. This divergence illustrates why AUROC or balanced accuracy alone can overstate positive-class retrieval under low prevalence. Endpoint-level PR-AUC, prevalence, repeat variability and class counts are reported in Supplementary Tables S6a, S8 and S10g and the machine-readable registry."
)
doc.add_paragraph("Selection-conditioned observed-versus-predicted examples remain available in the synchronized prediction files and separate software reports rather than as a best-case Supplement figure.")
doc.add_paragraph("Complete highlighted-model performance, uncertainty, class-size metrics and estimates grouped by TCGA tissue-source-site code are reported in Supplementary Table S6a and the machine-readable result files. The main text retains outcome-level summaries and illustrative figures.")
add_figure(doc, "Figure7_normalized_cancer_rates.png", "Figure 7. Catalogue-normalized effect-threshold crossing rates by cancer, outcome type and released representation. Each denominator is the set of eligible cancer–endpoint pairs for that cancer. Rates use Q²≥0.20 for continuous pairs and balanced accuracy≥0.60 for binary pairs. They describe task-level breadth within this correlated catalogue and should not be interpreted as numbers of independent biological discoveries.")

doc.add_heading("Metadata-stratified linear-model comparison", level=2)
doc.add_paragraph(
    f"The deterministic representative benchmark contained {len(ridge_binary)} binary and "
    f"{len(ridge_continuous)} continuous targets selected from all eligible tests without "
    f"reference to PLS performance; {len(ridge_screen_positive)}/{len(ridge_comparison)} happened to be screen-positive. "
    f"For binary targets, the median ridge-minus-PLS AUROC difference was "
    f"{fnum(binary_baseline_summary.get('median_delta_ridge_minus_pls'))} "
    f"(IQR {fnum(binary_baseline_summary.get('q1_delta'))} to {fnum(binary_baseline_summary.get('q3_delta'))}); "
    f"ridge had a selection-conditioned paired patient-resampling interval above zero for {sum(r.get('outcome_type') == 'binary' for r in ridge_better)} "
    f"{'model' if sum(r.get('outcome_type') == 'binary' for r in ridge_better) == 1 else 'models'}, "
    f"PLS for {sum(r.get('outcome_type') == 'binary' for r in pls_better)}, and "
    f"{sum(r.get('outcome_type') == 'binary' for r in baseline_uncertain)} AUROC differences were uncertain. "
    f"With the same inner-CV balanced-accuracy threshold rule applied to both methods, the median ridge-minus-PLS balanced-accuracy difference was "
    f"{fnum(binary_baseline_summary.get('median_secondary_delta_ridge_minus_pls'))} "
    f"(IQR {fnum(binary_baseline_summary.get('q1_secondary_delta'))} to {fnum(binary_baseline_summary.get('q3_secondary_delta'))}); "
    f"ridge had a selection-conditioned paired patient-resampling interval above zero for {len(binary_secondary_ridge)} "
    f"{'model' if len(binary_secondary_ridge) == 1 else 'models'}, PLS for {len(binary_secondary_pls)}, and "
    f"{len(binary_secondary_uncertain)} were uncertain. "
    f"For continuous targets, the median ridge-minus-PLS Q² difference was "
    f"{fnum(continuous_baseline_summary.get('median_delta_ridge_minus_pls'))} "
    f"(IQR {fnum(continuous_baseline_summary.get('q1_delta'))} to {fnum(continuous_baseline_summary.get('q3_delta'))}); "
    f"ridge was favoured for {sum(r.get('outcome_type') == 'continuous' for r in ridge_better)}, "
    f"PLS for {sum(r.get('outcome_type') == 'continuous' for r in pls_better)}, and "
    f"{sum(r.get('outcome_type') == 'continuous' for r in baseline_uncertain)} were uncertain. "
    f"For continuous Spearman correlation, ridge was favoured for {len(continuous_secondary_ridge)}, "
    f"PLS for {len(continuous_secondary_pls)} and {len(continuous_secondary_uncertain)} were uncertain. "
    "Thus the benchmark did not establish PLS superiority and more often favoured ridge, especially for continuous Q². These are representative paired comparisons rather than multiplicity-controlled algorithm discoveries or an atlas-wide ridge screen."
)

doc.add_heading("Secondary TITAN-specific tissue-source-site-code audit", level=2)
doc.add_paragraph(
    "The primary matched benchmark above evaluates grouping by TCGA tissue-source-site code in all three representations. This separate, larger audit uses the full TITAN cohort and its permutation/FDR-qualified candidate set; its estimates therefore answer a complementary question and are not directly substituted for the common-cohort results. "
    f"Internal validation grouped by TCGA tissue-source-site code was feasible for {sum(r.get('feasible')=='TRUE' for r in site_c)+sum(r.get('feasible')=='TRUE' for r in site_b)} TITAN screen-positive models. "
    f"Although the median grouped-minus-random performance change was only {fnum(median(site_deltas))}, "
    f"{ival(site_combined.get('below_threshold_models'))}/{ival(site_combined.get('screen_positive_models'))} "
    f"models ({fnum(site_combined.get('below_threshold_percent'), 1)}%) fell below the original documented screening threshold: "
    f"{sum(float(r.get('site_grouped_q2') or float('-inf')) < 0.20 for r in site_c if r.get('feasible') == 'TRUE')}/{len(site_c)} continuous models and {sum(float(r.get('site_grouped_balanced_accuracy') or float('-inf')) < 0.60 for r in site_b if r.get('feasible') == 'TRUE')}/{len(site_b)} binary models. Prominent attenuations were "
    f"{site_failure_text(site_named_failures)}. Folds grouped by TCGA tissue-source-site code contain fewer and less evenly distributed "
    "training and test patients, so the decline does not isolate a code-associated distribution effect; nevertheless, the near-chance "
    "colorectal APC results are not adequately summarised by the median and are prominently labelled as sensitive to grouping by TCGA tissue-source-site code in the registry and research-software output. "
)
doc.add_paragraph(
    f"Across {len(site_fold_details):,} outer folds, test partitions contained 1–445 patients and 1–9 TCGA tissue-source-site codes; binary folds contained 0–130 positive and 0–269 negative patients. These imbalances are intrinsic to keeping complete code groups together and are reported model by model and fold by fold. The deterministic fold audit confirmed that no TCGA tissue-source-site code crossed an outer fold and that the same separation was maintained in every inner component-selection split."
)
if site_partition_summary:
    binary_control = site_control_by_type["binary"]
    continuous_control = site_control_by_type["continuous"]
    coad_apc_control = site_control_apc.get(("COAD", "APC"), {})
    read_apc_control = site_control_apc.get(("READ", "APC"), {})
    doc.add_paragraph(
        f"The matched-partition control reproduced outer test-set sizes for all {len(site_c) + len(site_b)} models and positive/negative counts for all {len(site_b)} binary models. Relative to these matched random partitions, the median grouped-minus-matched-random change was "
        f"{fnum(binary_control.get('median_grouped_minus_matched'), 3)} for binary balanced accuracy and {fnum(continuous_control.get('median_grouped_minus_matched'), 3)} for continuous Q². "
        f"Paired patient-resampling intervals lay wholly below zero for {ival(binary_control.get('intervals_below_zero'))}/{len(site_b)} binary and {ival(continuous_control.get('intervals_below_zero'))}/{len(site_c)} continuous models; they included zero for {ival(binary_control.get('intervals_include_zero'))} and {ival(continuous_control.get('intervals_include_zero'))}, respectively. "
        "Thus, smaller or less balanced folds explain part of the aggregate attenuation, while a subset retained additional sensitivity associated with holding complete codes apart."
    )
    doc.add_paragraph(
        f"The paired control retained marked APC sensitivity: COAD–APC changed from matched-random balanced accuracy {fnum(coad_apc_control.get('matched_random_metric'), 3)} to grouped {fnum(coad_apc_control.get('grouped_metric'), 3)} (Δ {fnum(coad_apc_control.get('grouped_minus_matched'), 3)}; 95% paired interval {fnum(coad_apc_control.get('paired_ci_low'), 3)} to {fnum(coad_apc_control.get('paired_ci_high'), 3)}), and READ–APC changed from {fnum(read_apc_control.get('matched_random_metric'), 3)} to {fnum(read_apc_control.get('grouped_metric'), 3)} (Δ {fnum(read_apc_control.get('grouped_minus_matched'), 3)}; {fnum(read_apc_control.get('paired_ci_low'), 3)} to {fnum(read_apc_control.get('paired_ci_high'), 3)}). "
        f"Code alone yielded cross-validated AUROCs of {fnum(coad_apc_control.get('code_only_metric'), 3)} and {fnum(read_apc_control.get('code_only_metric'), 3)}. Restricting the descriptive prevalence range to codes with at least five patients, APC prevalence ranged from {fnum(coad_apc_control.get('minimum_prevalence_minimum5'), 3)} to {fnum(coad_apc_control.get('maximum_prevalence_minimum5'), 3)} across {ival(coad_apc_control.get('codes_with_minimum5'))} COAD codes and from {fnum(read_apc_control.get('minimum_prevalence_minimum5'), 3)} to {fnum(read_apc_control.get('maximum_prevalence_minimum5'), 3)} across {ival(read_apc_control.get('codes_with_minimum5'))} READ codes. This demonstrates strong code-associated outcome heterogeneity for these endpoints, but it does not identify whether its source is technical acquisition, molecular case mix, ancestry, referral or another code-associated factor."
    )
doc.add_paragraph(
    f"The dedicated within-cancer classification of TCGA tissue-source-site code analysis was evaluable in {len(site_predictability_eligible)}/32 cancers and included {sum(ival(r.get('analysed_patients')) for r in site_predictability_eligible):,} patients from codes represented by at least 10 patients. All 27 observed macro balanced accuracies exceeded their cancer-specific 1/k chance reference; the median was {fnum(median([r.get('macro_balanced_accuracy_mean') for r in site_predictability_eligible]))} (range {fnum(min(float(r.get('macro_balanced_accuracy_mean')) for r in site_predictability_eligible))}–{fnum(max(float(r.get('macro_balanced_accuracy_mean')) for r in site_predictability_eligible))}). The strongest chance-normalised code predictability occurred in "
    + "; ".join(
        f"{r.get('tumor_type')} (macro balanced accuracy {fnum(r.get('macro_balanced_accuracy_mean'))}; {ival(r.get('analysed_sites'))} codes)"
        for r in site_predictability_ranked[:5]
    )
    + ". ACC, CHOL, DLBC, MESO and UCS had fewer than two codes meeting the 10-patient requirement and were reported as ineligible. This result shows a held-out statistical association between the fixed TITAN representation and TCGA tissue-source-site code. It quantifies code-associated information in the embedding but does not establish that a particular endpoint model is confounded or identify causal scanner, laboratory, staining, population or biological information."
)

doc.add_heading("Multiple-slide sensitivity", level=2)
doc.add_paragraph(
    f"Replacing each deterministic patient mean with the coordinate-wise median produced median performance changes of {fnum(median_pool_by_type.get('continuous', {}).get('median_delta'))} Q² across 219 continuous models and {fnum(median_pool_by_type.get('binary', {}).get('median_delta'))} balanced accuracy across 104 binary models; mean-versus-median rankings remained highly concordant (Spearman {fnum(median_pool_by_type.get('continuous', {}).get('correlation_with_mean'))} and {fnum(median_pool_by_type.get('binary', {}).get('correlation_with_mean'))}, respectively). The original threshold was retained by {ival(median_pool_by_type.get('continuous', {}).get('retained_original_effect_threshold'))}/219 and {ival(median_pool_by_type.get('binary', {}).get('retained_original_effect_threshold'))}/104 models. The lexicographically first-slide sensitivity was less stable: its median changes were {fnum(statistics.median(float(r['delta_first_minus_mean']) for r in pool_c))} and {fnum(statistics.median(float(r['delta_first_minus_mean']) for r in pool_b))}, with rank correlations 0.964 and 0.921. Across multi-slide patients, median pairwise cosine distance and maximum leave-one-slide-out centroid change are reported separately for all three representations in Supplementary Table S3d. Refitting after removing TCGA-DX-AB2L retained the original threshold for {sum(float(r.get('exclusion_q2', 'nan')) >= 0.20 for r in sarc_exclusion_c)}/15 SARC continuous and {sum(float(r.get('exclusion_balanced_accuracy', 'nan')) >= 0.60 for r in sarc_exclusion_b)}/5 SARC binary candidates. IFN-gamma Response (Q² 0.233 to 0.183), Macrophages M0 (0.211 to 0.163) and the TP53 mutation model (balanced accuracy 0.617 to 0.589) fell below threshold. This patient-level sensitivity is distinct from validation grouped by TCGA tissue-source-site code."
)
doc.add_paragraph("Mean pooling limits numerical dominance by heavily sampled participants because each participant remains one validation observation, but it cannot rescue a patient whose eligible slides are uniformly non-representative of the molecularly profiled tumour. The 30-slide SARC example therefore motivates future independent pathology QC and tumour-area-aware aggregation rather than a claim that equal pooling solved tissue adequacy.")

doc.add_paragraph("TITAN-specific qualitative neighbour retrieval and morphology-context examples are reported in Supplementary Table S14 and morphology_context_examples.csv. They are hypothesis-generating and are not patch-level attribution or independent pathology validation.")

doc.add_heading("Tertiary layer: PathoFMPred research framework", level=2)
doc.add_paragraph(f"PathoFMPred creates no new performance evidence. Its controlled registry contains {registry_object_total} representation-specific fitted objects, but object counts do not reproduce the representation-specific crossing counts. The {inventory_by_representation['GigaSSL']} Giga-SSL and {inventory_by_representation['ProvGigaPath']} Prov-GigaPath objects use the identical shared set of 297 TITAN-qualified matched-eligible targets (198 continuous; 99 binary), irrespective of whether that alternative representation crossed. Therefore 12/105 continuous and 13/63 binary Giga-SSL crossings and 18/130 continuous and 15/76 binary Prov-GigaPath crossings currently lack controlled objects, while 105/198 continuous and 49/99 binary Giga-SSL objects and 86/198 continuous and 38/99 binary Prov-GigaPath objects are tested-below-threshold fits. The registry and compare_pathofm_models() expose object availability, target-selection basis, matched-threshold status and absence of representation-specific permutation/FDR qualification as separate fields. Object availability is not interpreted as crossing, consensus or an additional validation tier, and the registry is not a complete operationalization of the multi-representation atlas.")
doc.add_paragraph("No non-TCGA patient entered model evaluation, and no external performance result is reported. The prospectively locked targets and protocol for future independent evaluation are provided in Supplementary Table S6c and the software documentation; this wording is supported by a separate pre-result protocol commit.")

doc.add_heading("Illustrative COAD research-software profiles", level=2)
if len(coad_examples) >= 2:
    case_a, case_b = coad_examples[:2]
    doc.add_paragraph(
        f"Figure 8 retains two deliberately selected COAD examples solely to show the research interface: "
        f"{case_a.get('patient_id')} and {case_b.get('patient_id')}. {case_a.get('shared_features')} "
        "After these clinical-text and profile-saturation restrictions, the pair maximising Euclidean separation "
        "across continuous TCGA out-of-fold reference ranks was selected; the contrast is therefore post hoc and "
        "not representative sampling, calibration, prognosis, treatment-response evidence or external validation. "
        "The radar corners print the original continuous predictions."
    )
add_figure(doc, "Figure8_COAD_PathoFMPred_examples.png", "Figure 8. Post hoc PathoFMPred research-software visualization for TCGA-AA-A01F and TCGA-A6-A56B using TITAN inputs. Panels A and B show the original continuous prediction values at every radar corner. The cases were deliberately selected to share reported clinicopathological features while contrasting their continuous prediction profiles; they are not a representative sample, calibration analysis or validation cohort. All estimates are internal to TCGA.")

# Rebuild the Results as a single benchmark-led scientific narrative.  The
# development version above deliberately retains every analysis while it is
# being assembled; the final journal version removes that accumulated block
# and restores only the elements needed to understand the primary matched
# benchmark.  TITAN-only depth, demographic auditing, morphology, software
# object reconciliation and the COAD radar demonstration remain in the
# Supplementary Material.
results_heading_element = next(p._element for p in doc.paragraphs if p.text == "Results")
results_body_element = results_heading_element.getparent()
while (results_heading_element.getnext() is not None
       and results_heading_element.getnext().tag != qn("w:sectPr")):
    results_body_element.remove(results_heading_element.getnext())

doc.add_heading("Matched cohort, released representations and common PLS-based probe", level=2)
doc.add_paragraph(
    f"The primary benchmark comprised {foundation_common_n:,} patients shared by TITAN, Giga-SSL and Prov-GigaPath and "
    "3,389 cancer–endpoint pairs (2,963 continuous and 426 binary) evaluated on identical outcome-labelled patients, "
    "folds, seeds and tuning rules. The patient was the unit of analysis and cross-validation, and eligible slides were "
    "pooled before outcomes were joined. The comparison therefore controls patient and endpoint composition but remains "
    "a comparison of complete released embedding pipelines—including upstream preprocessing, physical-resolution "
    "assumptions, released layers and representation-learning exposure—under the specified PLS regression/PLS-LDA probe."
)
doc.add_paragraph(
    f"Exactly identical slide sets were available for {ival(foundation_slide_audit.get('identical_slide_set_patients')):,}/"
    f"{ival(foundation_slide_audit.get('common_patients')):,} patients ({fnum(foundation_slide_audit.get('identical_slide_set_percent'), 2)}%). "
    f"Restricting all pipelines to the {ival(foundation_slide_audit.get('exact_common_slides')):,} exactly shared slides retained all "
    f"{foundation_common_n:,} patients and left median performance changes at approximately zero. Near-threshold membership changed for "
    "a small number of pairs, but the aggregate ordering was unchanged (Supplementary Table S15d)."
)
doc.add_paragraph("Table 2. Pathology-quality and molecular–slide linkage constraints applying to cross-modal interpretation. Generated narrative flags are same-image, non-adjudicated observations and were not used for primary inclusion, weighting or outcome definition.")
add_table(
    doc,
    ["Constraint", "Available information", "Observed extent", "Interpretive consequence"],
    [
        ["Structured pathology quality",
         "TCGA primary-tumour sample type and diagnostic-slide filename only",
         "No structured tumour cellularity, tissue area, artefact, biopsy/resection or slide-quality field",
         "Slide eligibility and equal weighting were not pathology adjudicated"],
        ["Generated no-residual-tumour text",
         "TITAN-generated narrative; not an independent pathology label",
         f"{ival(no_residual_patient_summary.get('flagged_slides'))} slides from {ival(no_residual_patient_summary.get('flagged_patients'))} patients in {ival(no_residual_patient_summary.get('affected_cancers'))} cancers",
         f"Non-adjudicated exclusion sensitivity: {no_residual_threshold_retained_total}/{no_residual_sensitivity_total} screen-positive models retained the original threshold"],
        ["Multiple diagnostic slides",
         "Arithmetic patient mean; each slide receives weight 1/n within patient",
         f"{n_multi:,}/{n_patients:,} patients had >1 slide; maximum 30",
         "Prevents participant over-weighting and leakage, but cannot ensure tumour representativeness"],
        ["Molecular–slide linkage",
         "Five sources resolved to a shared 15-character sample barcode; Thorsson was participant-only",
         f"Thorsson: {ival(linkage_by_source.get('Thorsson2018_PanImmune_MS', {}).get('covered_patients')):,} participant-linked patients",
         "Even an exact sample barcode does not establish the same portion, analyte, aliquot, block or tumour region"],
    ],
    widths=[3.0, 4.2, 4.0, 5.2], font_size=7.0, header_font_size=7.3,
    line_spacing=1.0, fixed_layout=True,
)
doc.add_paragraph(
    f"The generated-text sensitivity excluded all {ival(no_residual_patient_summary.get('flagged_patients'))} flagged patients before fold construction and refitted all {no_residual_sensitivity_total} screen-positive models in BRCA, LUAD, LUSC and SARC. The original effect threshold was retained by {no_residual_threshold_retained_total}/{no_residual_sensitivity_total} models. All four highlighted models retained their thresholds; the largest absolute change among them was {fnum(no_residual_highlighted_max_abs_delta)} Q². These results do not validate the narrative flags as pathology labels and do not replace independent slide review."
)

doc.add_heading("Provenance-stratified benchmark and catalogue context", level=2)
doc.add_paragraph(
    "Reference-label provenance was the first interpretive stratum. Among 243 directly observed genomic-alteration tasks, "
    "TITAN, Prov-GigaPath and Giga-SSL crossed for 137 (56.4%), 98 (40.3%) and 92 (37.9%). The corresponding counts were "
    "33/24/14 of 413 for sequencing-derived continuous burdens, 92/64/58 of 279 for transcriptomic signatures, "
    "447/305/249 of 1,456 RNA-derived pathway activities, 27/18/16 of 638 computationally inferred immune-cell fractions and 34/19/14 of 166 continuous composite "
    "genomic-context scores. These are held-out agreements with the supplied reference phenotypes. In particular, agreement "
    "with CIBERSORT fractions, methylation-derived leukocyte estimates or RNA signatures does not demonstrate analytical "
    "recovery of the originating assay or direct immune-cell abundance."
)
doc.add_paragraph(
    f"The matched TIL Regional Fraction tasks crossed in 10/11 TITAN, 11/11 Prov-GigaPath and 11/11 Giga-SSL analyses, but these were same-H&E computational "
    f"concordance tasks. Excluding them—the default continuous summary—TITAN crossed {cross_modal_continuous_label('TITAN')}, "
    f"Prov-GigaPath {cross_modal_continuous_label('ProvGigaPath')} and Giga-SSL {cross_modal_continuous_label('GigaSSL')}. "
    "RNA-derived pathway activities contributed 447/643 TITAN, 305/441 Prov-GigaPath and 249/362 Giga-SSL continuous crossings. Accordingly, raw task totals are retained only as "
    "secondary catalogue descriptors in Supplementary Tables S15 and S18, not as independent biological breadth or direct "
    "molecular-assay recovery."
)
doc.add_paragraph(
    "Table 3. Provenance-stratified crossings and the default same-H&E-excluded continuous summary. Crossings use Q²≥0.20 "
    "for continuous tasks and AUROC≥0.60 for binary tasks. The larger-sample stratum means n≥100 for continuous "
    "tasks or at least 50 patients per class for binary tasks; it is a denominator descriptor, not an evidence grade."
)
doc.add_paragraph("Panel A. Reference-label classes are not assay-equivalent.", style="Caption")
provenance_panel_rows = [
    ("binary", "directly observed genomic alteration", "Direct genomic alterations"),
    ("binary", "composite genomic-context score", "Composite genomic-context status"),
    ("continuous", "sequencing-derived continuous burden", "Sequencing-derived burdens"),
    ("continuous", "transcriptomic signature", "Transcriptomic signatures"),
    ("continuous", "transcriptomic pathway score", "RNA-derived pathway activities"),
    ("continuous", "computationally inferred immune-cell fraction", "Inferred immune-cell fractions"),
    ("continuous", "composite genomic-context score", "Composite genomic-context scores"),
    ("continuous", "pathology-associated quantity", "Same-H&E TIL fraction"),
]
add_table(
    doc,
    ["Reference-label class", "Outcome", "Eligible", "TITAN crossings", "Prov-GigaPath crossings", "Giga-SSL crossings"],
    [[label, outcome, foundation_provenance_by_key[("TITAN", outcome, cls)]["eligible_tasks"],
      provenance_crossing_label("TITAN", outcome, cls),
      provenance_crossing_label("ProvGigaPath", outcome, cls),
      provenance_crossing_label("GigaSSL", outcome, cls)]
     for outcome, cls, label in provenance_panel_rows],
    widths=[3.20, 1.35, 1.25, 2.60, 3.10, 2.60], font_size=6.5, header_font_size=6.7,
    line_spacing=1.0, fixed_layout=True,
)
doc.add_paragraph("Panel B. Same-H&E-excluded continuous rates are the default; all-outcome totals remain in Supplementary Table S18.", style="Caption")
add_table(
    doc,
    ["Representation", "Continuous excluding same-H&E, n/N (%)", "Larger-sample continuous excluding same-H&E, n/N (%)", "Binary, n/N (%)", "Larger-sample binary, n/N (%)", "Same-H&E TIL fraction"],
    [[display_representation(m), cross_modal_continuous_label(m), cross_modal_larger_sample_label(m),
      foundation_breadth_label(m, "binary"), foundation_standard_label(m, "binary"),
      {"TITAN": "10/11 (90.9%)", "ProvGigaPath": "11/11 (100.0%)", "GigaSSL": "11/11 (100.0%)"}[m]]
     for m in ("TITAN", "ProvGigaPath", "GigaSSL")],
    widths=[2.00, 3.10, 3.40, 2.20, 2.70, 2.00], font_size=6.2, header_font_size=6.4,
    line_spacing=1.0, fixed_layout=True,
)
doc.add_paragraph("Table 4. Technical scope of the released embedding pipelines. Potential TCGA overlap refers to representation development, not to downstream molecular-label fitting in this study.")
add_table(
    doc,
    ["Representation", "Pretraining / potential TCGA overlap", "Released representation", "Dimension", "Evaluation condition"],
    [
        ["TITAN", "Mass-340K; TCGA excluded from pretraining", "Official TITAN slide embedding", "768", "TCGA unseen in reported pretraining; used in published downstream evaluation"],
        ["Giga-SSL", "Development used TCGA; direct image overlap cannot be excluded", "TCGA_encoded_t5e1000", "512", "Downstream labels held out; images not necessarily unseen in representation learning"],
        ["Prov-GigaPath", "Providence WSIs; TCGA not reported as pretraining data", "Final public slide layer", "768", "TCGA unseen in reported pretraining"],
    ], widths=[2.10, 4.00, 3.00, 1.30, 4.60], font_size=7.0, header_font_size=7.2,
    line_spacing=1.0, fixed_layout=True,
)
add_figure(doc, "Figure2_biological_predictability_map.png", "Figure 2. Tumour features predictable from H&E under the common 1-to-20-component PLS-based probe. Panel A reports the proportion of eligible cancer–endpoint pairs that reached Q²≥0.20 or AUROC≥0.60 in at least one representation and in all three representations. Panels B and C compare selected genomic, pathway and immune-context examples across TITAN, Giga-SSL and Prov-GigaPath. The thresholds summarize catalogue breadth and are not inferential or clinical boundaries.")
add_figure(doc, "Figure4_observed_vs_predicted_TGCT_TGFbeta.png", "Figure 3. Observed and patient-level out-of-fold predictions for the TGCT TGF-beta response reference score. Each patient received one held-out prediction from TITAN, Giga-SSL and Prov-GigaPath under matched folds. Q² and Spearman correlation summarize agreement with the bulk-RNA-derived reference phenotype; the plots do not establish recovery of the originating assay.")

doc.add_heading("Continuous effects, ranks and alternative-partition stability", level=2)
doc.add_paragraph(
    f"Five new matched nested partitions were analysed for the fixed {len(foundation_fold_selection):,}-pair union-crossing or near-threshold set. For each representation–pair combination, the atlas reports the primary Q² or AUROC, the median and interquartile range across alternative partitions, the proportion of partitions crossing the pragmatic threshold and the selected-component distribution. The primary leading representation remained rank 1 in all five alternatives for "
    f"{winner_stability('continuous')['all_five']}/{winner_stability('continuous')['tasks']} continuous and {winner_stability('binary')['all_five']}/{winner_stability('binary')['tasks']} binary pairs, and in a majority for {winner_stability('continuous')['majority']}/{winner_stability('continuous')['tasks']} and {winner_stability('binary')['majority']}/{winner_stability('binary')['tasks']}. "
    f"For context only, the primary all-three threshold category persisted in all five for {consensus_class_stability('continuous', ['all three'])[0]}/{consensus_class_stability('continuous', ['all three'])[1]} continuous and {consensus_class_stability('binary', ['all three'])[0]}/{consensus_class_stability('binary', ['all three'])[1]} binary pairs; exactly-two and representation-specific categories were substantially less stable. These categorical labels are retained for search and navigation, not as the biological hierarchy."
)
doc.add_paragraph(
    f"The ranking was also conditional on the downstream probe. On the {ival(probe_by_type['binary']['targets']) + ival(probe_by_type['continuous']['targets'])}-target metadata-stratified subset, replacing PLS/PLS–LDA with ridge retained the leading representation for {ival(probe_by_type['binary']['winner_retained'])}/{ival(probe_by_type['binary']['targets'])} binary and {ival(probe_by_type['continuous']['winner_retained'])}/{ival(probe_by_type['continuous']['targets'])} continuous targets. The completed primary atlas used a 1-to-20-component search. At least one outer fit selected component 20 for 14.6% of Giga-SSL, 12.9% of Prov-GigaPath and 12.0% of TITAN binary tasks, compared with 0.2%, 0.5% and 0.1% of continuous tasks; no numerical failure was recorded. These sensitivities preclude an intrinsic foundation-model superiority claim and support carrying forward representation–probe pairs rather than a single universal ranking. The present comparison is explicitly limited to the common 1-to-20-component PLS-based probe, while ridge remains a targeted sensitivity rather than a second atlas."
)
add_figure(doc, "Figure3_effect_partition_stability.png", "Figure 4. Performance and partition sensitivity in the matched benchmark. Panel A compares each primary Q² or AUROC estimate with its median across five alternative matched partitions and shows the repeat interquartile range. Panel B compares tissue-source-site-code-grouped Q² or AUROC with a matched-random partition preserving outer-fold size and, for binary outcomes, class counts. Panel C reports the proportion of alternative partitions retaining the primary leading-representation rank. No panel converts the pragmatic crossing thresholds into inferential or clinical boundaries.")

doc.add_heading("Sensitivity to grouping by a barcode-derived cohort-structure variable", level=2)
doc.add_paragraph(
    f"Every one of the {foundation_union_counts['tasks']:,} pairs crossing in at least one representation was re-evaluated with complete TCGA tissue-source-site codes held apart "
    "in both outer and inner validation, with matched-random controls preserving outer-fold sizes and binary class counts. Among all-three pairs, "
    f"complete threshold retention occurred for {foundation_tss_consensus_counts[('continuous', 'all three', 'complete retention')]}/304 continuous and "
    f"{foundation_tss_consensus_counts[('binary', 'all three', 'complete retention')]}/122 binary pairs. Median grouped-minus-matched-random effects were −0.027/−0.005 Q²/AUROC for TITAN, −0.043/−0.015 for Giga-SSL and −0.059/−0.011 for Prov-GigaPath. Consensus therefore did not guarantee robustness to cohort structure. This is sensitivity to grouping by a barcode-derived cohort-structure variable, not institutional, scanner-level or external validation, and attenuation does not by itself prove technical confounding."
)
doc.add_paragraph(
    f"All grouped performance metrics were calculated once from pooled patient-level outer out-of-fold predictions; fold-specific metrics were not averaged. Outer test sets ranged from 1 to 317 patients, and 15 tasks used four rather than five folds. A descriptive sparse-fold flag was triggered for {foundation_tss_adequacy_by_outcome['binary']['tasks_with_sparse_grouped_folds']}/268 binary and {foundation_tss_adequacy_by_outcome['continuous']['tasks_with_sparse_grouped_folds']}/703 continuous tasks. Twenty-seven of 268 binary tasks, or 81/804 representation–task fits because folds were shared, had at least one single-class outer test fold; 114 had a single-class inner validation fold and two had a single-class inner training fold. Minimum outer training counts were 1 positive and 5 negative patients, and minimum inner training counts were 0 positive and 1 negative patient. The flag is an audit warning rather than an exclusion or validity threshold."
)

doc.add_heading("Supporting TITAN permutation/FDR analysis", level=2)
doc.add_paragraph(
    f"The supporting TITAN-only layer used the larger {n_patients:,}-patient cohort and evaluated {len(continuous) + len(binary):,} eligible pairs. "
    f"Of these, {titan_candidate_total} met both the outcome-specific effect threshold and the documented empirical-permutation/FDR rule. "
    f"When complete TCGA tissue-source-site codes were held apart, {ival(site_combined.get('below_threshold_models'))}/"
    f"{ival(site_combined.get('screen_positive_models'))} ({fnum(site_combined.get('below_threshold_percent'), 1)}%) fell below their original "
    "threshold. READ–APC and COAD–APC were prominent examples of attenuation toward chance. This deeper inferential qualification applies only "
    "to TITAN and does not convert the primary three-representation crossing counts into multiplicity-controlled discoveries."
)
doc.add_paragraph(
    f"This supporting TITAN layer is the source of the reported 1–445-patient outer-test range. Five of 104 binary models had a single-class outer test fold, 25 had a single-class inner validation fold and none had a single-class inner training fold; two of 219 continuous models used four outer folds. Minimum outer and inner binary training counts were 7/12 and 2/3 positive/negative patients. The sparse-fold flag applied to {titan_site_adequacy_by_outcome['binary']['models_with_sparse_grouped_folds']}/104 binary and {titan_site_adequacy_by_outcome['continuous']['models_with_sparse_grouped_folds']}/219 continuous models. These are also sensitivity analyses grouped by the barcode-derived cohort-structure variable, not evidence of generalisability."
)
doc.add_paragraph(
    f"The inclusive TITAN layer retained {len(supported_c)} continuous and {len(supported_b)} binary candidates; {len(continuous_standard)} and {len(binary_standard)}, respectively, were in the larger-sample stratum. Smaller-sample models remain visible with explicit denominator warnings. Every eligible "
    "pair that did not enter permutation testing was explicitly assigned raw p=1 and retained in all applicable Benjamini–Hochberg denominators; "
    "early-stopped permutation tests were labelled separately. Complete performance, multiplicity, repeated-validation, class-size, continuous-reliability, "
    "grouped-partition and pathology-QC results are reported in Supplementary Tables S1-S10 and Figures S1, S2 and S4."
)

doc.add_heading("Translational interpretation", level=2)
doc.add_paragraph(
    "The benchmark does not reduce translational interpretation to threshold categories. Representative sequence-based examples include THYM–GTF2I, THCA–BRAF, LGG–IDH1 and LGG–TP53; derived-phenotype examples include TGCT TGF-beta response, TGCT leukocyte fraction and LIHC wound healing. Each is reported with its continuous Q²/AUROC estimate, alternative-partition distribution and rank stability, grouped estimate, matched-random difference and sample-size stratum, and each is interpreted according to its source modality rather than as a clinical evidence grade or direct immune-cell measurement."
)
doc.add_heading("PathoFMPred output for two illustrative COAD patients", level=2)
if len(coad_examples) >= 2:
    case_a, case_b = coad_examples[:2]
    doc.add_paragraph(
        f"The research-software illustration uses {case_a.get('patient_id')} and {case_b.get('patient_id')}. "
        f"{case_a.get('shared_features')} The pair was selected after restricting the candidate set and therefore does not represent random sampling, calibration, prognosis or treatment-response evidence. Figure 5 shows only continuous endpoints that met the recorded predictability rule for each cancer and representation. Original predicted values appear beside the endpoint names; the radial position is an internal TCGA reference rank and is not a probability."
    )
add_figure(doc, "Figure3_COAD_PathoFMPred_multifoundation_examples.png", "Figure 5. PathoFMPred continuous profiles for TCGA-AA-A01F and TCGA-A6-A56B. Rows show TITAN, Giga-SSL and Prov-GigaPath inputs; columns show the two patients. Each panel contains only endpoints classified as predictable for that cancer and representation. Corner labels give the original prediction; radial positions are internal TCGA reference percentiles, not probabilities or clinical reference intervals.", width=6.15)
doc.add_paragraph(
    "Figure 6 displays every predictable binary COAD feature returned by at least one of the three representation-specific objects. It gives the final class call, original uncalibrated LDA score and internal TCGA score rank. A grey cell means that the selected representation did not return an eligible threshold-crossing object for that endpoint. The figure demonstrates the report interface and representation-dependent calls; molecular reference labels were unavailable for these two illustrative patients and no call is presented as a clinical diagnosis."
)
add_figure(doc, "Figure6_COAD_PathoFMPred_full_binary_output.png", "Figure 6. Complete PathoFMPred binary output for the two illustrative COAD patients across TITAN, Giga-SSL and Prov-GigaPath. Red and blue cells give positive and negative research class calls. Each returned cell also reports the original uncalibrated LDA score and internal TCGA score rank. Reference rank is not probability. Grey cells indicate that the representation did not return a predictable fitted object for that feature.", width=5.75)
doc.add_page_break()
def partition_audit_triplet(r, field, digits=3):
    return " / ".join(
        fnum(foundation_effect_partition_map.get(
            (r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"], model), {}
        ).get(field), digits)
        for model in ("TITAN", "GigaSSL", "ProvGigaPath")
    )

def partition_repeat_triplet(r):
    values = []
    for model in ("TITAN", "GigaSSL", "ProvGigaPath"):
        z = foundation_effect_partition_map.get(
            (r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"], model), {}
        )
        values.append(
            f"{fnum(z.get('repeat_effect_median'), 3)} "
            f"({fnum(z.get('repeat_effect_q25'), 3)}–{fnum(z.get('repeat_effect_q75'), 3)})"
        )
    return " / ".join(values)

def grouped_delta_triplet(r):
    values = []
    for model in ("TITAN", "GigaSSL", "ProvGigaPath"):
        z = foundation_effect_partition_map.get(
            (r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"], model), {}
        )
        values.append(
            f"{fnum(z.get('grouped_effect'), 3)} "
            f"(Δ{fnum(z.get('grouped_minus_matched_effect'), 3)})"
        )
    return " / ".join(values)

table4_examples = [r for i, r in enumerate(translational_consensus_examples)
                   if i in {0, 2, 3, 4, 5, 6, 8, 9}]
doc.add_paragraph("Table 5. Representative cancer–endpoint pairs reported with continuous performance and stability fields. C/B denotes continuous/binary; T/G/P denotes TITAN/Giga-SSL/Prov-GigaPath. Primary and grouped effects are Q² for continuous pairs and AUROC for binary pairs. Repeat values are medians (interquartile ranges) over five new matched partitions. Crossing proportions use pragmatic catalogue thresholds but are not evidence grades. Δ is grouped minus matched-random performance.")
add_table(
    doc,
    ["Target [C/B]", "Primary T/G/P", "Repeat median (IQR) T/G/P", "Crossing prop. T/G/P", "Winner rank repeats", "Grouped (Δ) T/G/P", "n stratum"],
    [[f"{r['tumor_type']}\n{r['endpoint']}\n[{'C' if r['outcome_type'] == 'continuous' else 'B'}]",
      partition_audit_triplet(r, "primary_effect"), partition_repeat_triplet(r),
      partition_audit_triplet(r, "crossing_proportion", 1),
      f"{int(round(5 * float(foundation_effect_partition_map.get((r['outcome_type'], r['family'], r['tumor_type'], r['endpoint'], 'TITAN'), {}).get('primary_winner_repeat_proportion', 0))))}/5",
      grouped_delta_triplet(r),
      foundation_effect_partition_map.get((r['outcome_type'], r['family'], r['tumor_type'], r['endpoint'], 'TITAN'), {}).get('sample_size_stratum', 'NA').replace('-sample', '')]
     for r in table4_examples],
    widths=[2.4, 1.6, 2.8, 1.8, 1.5, 2.7, 1.4],
    font_size=6.2, header_font_size=6.4, line_spacing=0.9,
    fixed_layout=True,
)
doc.add_paragraph(
    "The main manuscript therefore treats the matched benchmark as the scientific study, the TITAN permutation/FDR analysis as supporting depth, "
    "and PathoFMPred as supplementary infrastructure. Demographic subgroup auditing, qualitative morphology neighbours, fitted-object reconciliation, "
    "and detailed licensing and object-inventory records are retained in the Supplementary Material because they do not add comparative performance evidence."
)

doc.add_heading("Discussion", level=1)
doc.add_paragraph("The matched atlas identifies several classes of histology-predictable tumour features. At least one representation reached the effect threshold for 160/243 directly observed genomic alterations, 108/183 binary genomic-context states, 39/413 sequencing-derived burdens, 101/279 transcriptomic signatures, 486/1,456 RNA-derived pathway activities, 31/638 inferred immune-cell fractions and 35/166 continuous genomic-context scores. All three representations retained 65, 57, 10, 51, 209, 13 and 11 of these tasks, respectively. Strong shared examples included THYM GTF2I, THCA BRAF, LGG TP53, strict COAD MSI and TGCT TGF-beta response. The highest-performing representation varied by cancer and endpoint, so the atlas supports feature-specific model selection rather than one universal pipeline.")
doc.add_paragraph(f"The study compares complete released embedding pipelines with a reproducible analysis interface and model registry. TITAN had the highest overall task crossing rates and unique endpoint-definition coverage under the specified 1-to-20-component PLS-based probe, while Giga-SSL or Prov-GigaPath yielded higher effect statistics for many individual cancer–endpoint pairs. The matched atlas contained {len(endpoint_definitions):,} unique endpoint definitions rather than {len(foundation_target_comparison):,} independent biological questions, and related endpoints were correlated and repeated across cancers. RNA-derived pathway activity contributed most continuous crossings in every representation. Macro-averaging by family and cancer and counting cancers retained per endpoint therefore accompany raw task totals. This ordering remains conditional on catalogue composition, upstream preprocessing, physical resolution, representation-learning exposure, released layers, the downstream probe and the TCGA embedding artifacts. It is not an unrestricted ranking of intrinsic foundation-model quality. Matched-atlas crossings are descriptive and must not be conflated with the separately permutation/FDR-filtered TITAN results or with fitted-object availability.")
doc.add_paragraph("The three-way comparison is translationally relevant because an association that depends strongly on one representation is a weaker candidate for locked evaluation than one retained across distinct pretraining strategies. Cross-representation retention is not independent validation: all embeddings derive from TCGA slides, share the same outcomes and may encode the same cohort-specific artefacts. It nevertheless provides a practical robustness axis for selecting targets for a future locked study. PathoFMPred exposes the recorded representation and evidence metadata without silently assuming that one foundation model is universally preferable; because its controlled objects cover only a subset of atlas crossings, atlas-level consensus must be read from the benchmark results rather than inferred from object availability.")
doc.add_paragraph("The combined consensus and TCGA tissue-source-site-code audit sharpens prioritisation. TGCT TGF-beta response, THYM GTF2I, THCA BRAF, strict COAD MSI and LGG TP53 were strong shared associations, but consensus did not guarantee stability under grouped partitions. The colorectal APC results were particularly sensitive to holding complete tissue-source-site codes apart. Other tasks retained useful grouped performance in all three representations. Consensus, discordance and cohort-structure sensitivity are therefore reported jointly rather than using aggregate crossing counts as the translational ranking.")
doc.add_paragraph("Matching patients alone did not guarantee identical histological input. The slide-set audit found exact agreement for 99.59% of common patients and differences for 34 patients. Repeating the complete atlas after restricting every representation to 10,165 exactly shared slides retained all 8,241 patients and left median performance changes at approximately zero, although some near-threshold tasks changed screening membership. This sensitivity supports the aggregate atlas conclusion but does not prove that residual differences arise solely from model architecture: the public embedding resources also differ in tissue processing, tiling, patch encoders, training objectives and implementation details.")
doc.add_paragraph("The closest breadth comparator is Arslan et al., who trained 12,093 target-specific models for 4,031 multi-omic biomarkers in 8,890 TCGA patients across 32 cancers [13]. The present study is smaller in endpoint breadth and lacks external validation. It adds a matched comparison of three released slide representations, deterministic pre-outcome patient aggregation, nested patient-level validation, complete tested-negative and ineligible outputs, target-level sensitivity to grouping by TCGA tissue-source-site code, continuous modelling of immune, genomic-context and pathway scores, and portable linear fitted objects where upstream terms permit redistribution.")
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
    "The literature cross-check also identified mutation pairs that earlier studies evaluated without "
    "statistical support. THYM–GTF2I was not identified in the reviewed predictive-model literature, "
    "although a direct GTF2I–thymoma morphology association is established. These findings are therefore "
    "presented as candidates for independent validation rather than claims of biological novelty. "
    "Supplementary Table S10a and the machine-readable audit report the evidence scope, prior metric, "
    "source and interpretation for every mutation pair."
)
doc.add_paragraph(
    "External results also caution against equating internal discrimination with transportability. For PAAD–TP53, "
    "the current TCGA balanced accuracy was 0.619 and Arslan et al. reported mean internal AUROC 0.672, "
    "whereas Saldanha et al. reported internal AUROC 0.554 and external CPTAC AUROC 0.443±0.064 [11,13]. "
    "Differences can arise from cohort composition, slide preparation, mutation definition, model class and "
    "validation design. The present result therefore supports further locked external testing, not clinical application."
)
doc.add_paragraph("The non-mutation endpoints extend the analysis beyond the exact cancer–gene pairs used for the literature crosswalk, but they must not be collapsed under the phrase 'immune measurements'. Direct sequence-supported alterations, sequencing-derived burdens, inferred immune-cell fractions, transcriptomic signatures, pathology-derived quantities and composite genomic-context scores have different error models and biological meanings. In particular, prediction of a CIBERSORT fraction or RNA signature is agreement with a computational phenotype derived from a bulk specimen; it is not equivalent to flow cytometry, immunohistochemistry, a direct cell count or a clinically certified biomarker. TIL Regional Fraction is an even more specific same-modality case because both predictor and target originate from H&E. Its result is best interpreted as concordance between two image-derived summaries rather than molecular inference.")
doc.add_paragraph(f"For continuous outcomes, prior work predicted RNA expression [6], tumour composition [4], continuous HRD and microenvironment features [12], and externally evaluated tumour-microenvironment composition in non-small cell lung cancer [15]. The present study instead screens the documented Thorsson-derived panel, genomic-context scores, MSI scores, fusion burden and aneuploidy burdens across eligible TCGA cancers using the same patient-level validation design. Only {len(global_supported_c)} continuous pairs passed the stricter across-cancer correction; the others should be treated as endpoint- and cancer-specific nominations, not as replications of the external HistoTME results or as evidence of general immune profiling.")
doc.add_paragraph("The contribution is therefore not that TITAN plus PLS is an optimal algorithmic combination. It is the uniform, auditable patient-level screen over documented outcomes using one fixed representation, complete negative reporting and compact fitted reference models. PLS regression and PLS-LDA remain the documented reference analysis, but the released PLS objects should not be interpreted as the best available models.")
doc.add_paragraph(f"The revision-added metadata-stratified benchmark directly weakens any stronger PLS claim. Selection depended only on outcome family, sample size, binary minority-class fraction and a fixed hash, not on PLS performance. Both algorithms used matched outer and inner folds; continuous hyperparameters maximised the same pooled inner Q² and binary thresholds maximised the same inner balanced accuracy. Median ridge-minus-PLS differences were {fnum(binary_baseline_summary.get('median_delta_ridge_minus_pls'))} AUROC and {fnum(continuous_baseline_summary.get('median_delta_ridge_minus_pls'))} Q². Paired intervals favoured ridge for {sum(r.get('outcome_type') == 'binary' for r in ridge_better)}/{len(ridge_binary)} binary and {sum(r.get('outcome_type') == 'continuous' for r in ridge_better)}/{len(ridge_continuous)} continuous targets, PLS for none, and were otherwise uncertain. Portability cannot justify PLS over ridge because both yield compact exportable parameters. We did not retroactively replace the original TITAN analysis or switch methods within it; instead, we report PLS as the documented reference and make clear that future independent evaluations should commit the PLS-versus-ridge comparison before inspecting external outcomes.")
doc.add_paragraph("The secondary comparison of single-outcome and multi-outcome PLS for inflammatory outcomes is reported in the Supplement. Its positive internal averages motivate future multi-outcome modelling but do not alter the endpoint-specific three-representation atlas or establish a preferable model without external validation.")
doc.add_paragraph(f"The documented 20-per-class rule supported an inclusive atlas screen, but it was too permissive for presenting every selected binary model as equally mature. Only {len(binary_standard)}/{len(supported_b)} screen-positive binary models met the stricter 50-per-class criterion. The {len(binary_limited_reliability)} smaller-class models had sparse inner validation folds, frequently selected components across a wide range and showed lower median repeat score correlation than the ≥50-per-class group. Their learning curves showed no uniformly monotonic performance gain, illustrating that the available data cannot establish a stable sample-size plateau. We therefore retain them only as transparently reported exploratory results and exclude them from default inference. PR-AUC adds prevalence-aware discrimination information, whereas PPV and NPV are explicitly conditional on each analysed TCGA prevalence and should not be exported to another population. High call agreement under imbalance can be misleading and does not supersede score stability, sensitivity, PR-AUC or external validation.")
doc.add_paragraph("Continuous evidence maturity showed a related but not identical pattern. The 13 candidates below 100 labelled patients had lower median repeat-prediction stability and larger repeat-to-repeat Q² variation than the 206 larger models, although mean Q² itself was not monotonically related to sample size. Component-ceiling selection was uncommon in both groups. We therefore use the <100 label as a conservative, revision-added warning and default-interface rule, not as evidence that every smaller result is false or every larger result is stable.")
doc.add_paragraph(
    f"Cohort-structure sensitivity is part of the primary evidence hierarchy. In the matched three-representation analysis, the original effect threshold was retained for {foundation_tss_retention('TITAN', 'continuous')[0]}/{foundation_tss_retention('TITAN', 'continuous')[1]} TITAN, {foundation_tss_retention('GigaSSL', 'continuous')[0]}/{foundation_tss_retention('GigaSSL', 'continuous')[1]} Giga-SSL and {foundation_tss_retention('ProvGigaPath', 'continuous')[0]}/{foundation_tss_retention('ProvGigaPath', 'continuous')[1]} Prov-GigaPath continuous crossings, and for {foundation_tss_retention('TITAN', 'binary')[0]}/{foundation_tss_retention('TITAN', 'binary')[1]}, {foundation_tss_retention('GigaSSL', 'binary')[0]}/{foundation_tss_retention('GigaSSL', 'binary')[1]} and {foundation_tss_retention('ProvGigaPath', 'binary')[0]}/{foundation_tss_retention('ProvGigaPath', 'binary')[1]} binary crossings. Complete grouped retention occurred in only {foundation_tss_consensus_counts[('continuous', 'all three', 'complete retention')]}/87 continuous and {foundation_tss_consensus_counts[('binary', 'all three', 'complete retention')]}/43 binary all-three tasks. Thus, representation consensus did not imply robustness to cohort structure. The R1–R4 internal prioritisation classes combine consensus, sample-size maturity and grouped retention, but are neither clinical evidence grades nor proof of transportability."
)
doc.add_paragraph(f"The larger TITAN-only layer reinforces this conclusion: {ival(site_combined.get('below_threshold_models'))}/{ival(site_combined.get('screen_positive_models'))} permutation/FDR-qualified candidates ({fnum(site_combined.get('below_threshold_percent'), 1)}%) fell below their original documented screening threshold. READ–APC and COAD–APC declined from balanced accuracies 0.862 and 0.793 to 0.495 and 0.543, respectively. These estimates establish sensitivity to the partitioning scheme, not confounding. Grouped folds alter effective training size, test size, class balance and distribution simultaneously; affected models therefore carry a prominent partition-sensitivity warning without being labelled biological or artifactual. The model registry and inference output expose the grouped metric, delta, number of TCGA tissue-source-site codes, threshold-retention status and warning for every affected endpoint.")
doc.add_paragraph(f"The matched-random analysis narrows but does not eliminate this ambiguity. After matching outer test sizes and, for binary outcomes, exact class counts, median grouped penalties were {fnum(site_control_by_type.get('binary', {}).get('median_grouped_minus_matched'), 3)} balanced-accuracy units and {fnum(site_control_by_type.get('continuous', {}).get('median_grouped_minus_matched'), 3)} Q² units. Most paired intervals included zero, indicating that the dramatic unadjusted count of threshold losses should not be read uniformly as code-associated distribution shift. Conversely, the wholly negative paired intervals and high code-only AUROCs for COAD–APC and READ–APC show that their attenuation was not explained by outer-fold size or binary class count alone. Code predictability from TITAN and code-only outcome predictability establish two necessary ingredients for possible confounding, but not the causal link between them. TCGA tissue-source-site code correlates with biological case mix, subtype, ancestry, outcome prevalence and referral patterns as well as technical acquisition. The barcode-derived code is not an institution, scanner, staining laboratory or batch identifier; neither grouped retention nor attenuation proves transportability or technical confounding.")
doc.add_paragraph("A further practical feature is data-minimising model portability. Preprocessing values, latent weights and coefficients are sufficient for continuous prediction, with compact LDA parameters added for binary classification. The access-controlled PathoFMPred package applies cancer-matched models to correctly ordered TITAN, Giga-SSL or Prov-GigaPath features without requiring the original patient embeddings or outcomes [32]. The selected representation is explicit in both input validation and output. Its private status is stated explicitly; the manuscript makes no public-artifact availability claim. This design reduces the patient-level data exchanged in authorised research, although it does not itself confer privacy, satisfy local governance requirements or establish transportability.")
doc.add_paragraph("Strengths include primary-tumour matching across every data source, deterministic mean pooling of multiple slides, nested patient-level validation, FDR control within cancer and endpoint family, exact negative-result reporting, sensitivity analysis grouped by TCGA tissue-source-site code, saved research models and executable inference code. The supplied Bonneville spreadsheets contained only an ACC/CESC/MESO subset; cBioPortal PanCancer Atlas MANTIS fields were therefore used for full coverage and agreed exactly for all 387 overlapping cases.")
doc.add_paragraph("The principal limitation is absence of independent external validation. TCGA resampling—including the analysis termed 'internal validation grouped by TCGA tissue-source-site code'—cannot establish transportability to another institution, scanner, stain distribution or patient population. The TCGA tissue-source-site code is not an institution, scanner or laboratory identifier. The study is retrospective and exploratory; thresholds are prioritisation rules, not clinical operating points. Although TCGA was excluded from TITAN's Mass-340K pretraining corpus, it was used in the original paper's downstream evaluation; the present cohort is therefore neither a pretraining cohort nor an independent validation cohort. Predictability means cross-validated statistical association only: it does not establish biological causality, reveal a mechanism, reproduce the analytical validity of the source measurement or justify omitting or replacing a molecular or immune assay. The three-model UCEC subset is locked only for future independent evaluation. Until that untouched analysis reports every target, the work should be evaluated as a computational pathology benchmark and research-software resource rather than a translational prediction study.")
doc.add_paragraph("The reported uncertainty is deliberately labelled a 95% selection-conditioned patient-resampling interval for repeated out-of-fold predictions. It represents patient sampling variability conditional on the five fitted nested-CV prediction sets and incorporates the five repeat-specific metrics into each bootstrap calculation. It does not repeat the initial screen or highlighting decision, generate new fold partitions, re-estimate scaling, reselect components, refit a model, correct winner's-curse optimism, or sample a new institution, scanner, staining process or population. It is therefore not a conventional confidence interval for model generalisation or an external-performance interval; locked-model evaluation in an untouched cohort is required for transportability assessment.")
doc.add_paragraph(f"Arithmetic mean pooling gives each eligible slide equal within-patient weight and prevents multiple-slide leakage, but it does not model tumour content, variable tissue area, artefact, specimen procedure, slide quality or spatially resolved within-patient heterogeneity. Median pooling yielded nearly identical atlas rankings, while pairwise cosine dispersion and leave-one-slide-out centroid changes quantify—but do not biologically adjudicate—slide heterogeneity. No structured fields for those quantities were available, and no independent pathology review was performed. Generated narratives mentioned no residual tumour in {ival(no_residual_patient_summary.get('flagged_slides'))} slides from {ival(no_residual_patient_summary.get('flagged_patients'))} patients; 30 belonged to TCGA-DX-AB2L (SARC). Excluding all six flagged patients and refitting the {no_residual_sensitivity_total} screen-positive models in their four cancers retained the original threshold for {no_residual_threshold_retained_total} models. All four highlighted models retained their thresholds, with a maximum absolute Q² change of {fnum(no_residual_highlighted_max_abs_delta)}. These same-image automated narratives cannot serve as ground truth, and this non-adjudicated sensitivity cannot replace pathology-screened, learned or tissue-area-weighted aggregation. Molecular labels add a separate resolution limit: five sources permitted 15-character sample-barcode concordance, but Thorsson outcomes were participant-linked only, and no source established identity of the molecular aliquot, tissue portion, block or tumour region. Consequently, tissue representativeness, block-level heterogeneity and subclonal mismatch remain unavoidable sources of label noise.")
doc.add_paragraph("The 768-dimensional TITAN representation is not morphologically self-explanatory. The new high/low anchor and within-cancer nearest-neighbour analysis places representative predictions in the context of globally similar patient embeddings and preserves exact slide/report provenance, but it cannot determine which patch or tissue compartment drove a prediction. The available TCGA-Slide-Reports text was generated by TITAN from the same slides and is neither an independent annotation nor a blinded pathologist review. Consequently, descriptive terms such as lymphoid infiltrate, stromal pattern or necrosis are hypotheses for future review, not validated mechanisms. Tile-level representations or relevance maps retained prospectively, followed by blinded pathologist assessment, are required before morphological explanations can be claimed.")
doc.add_paragraph(f"The post hoc subgroup audit was denominator-limited and does not establish algorithmic fairness. Both recorded-sex groups were estimable for {subgroup_two_group_models['continuous_sex']} continuous and {subgroup_two_group_models['binary_sex']} binary high-volume targets, whereas at least two broad race groups were estimable for only {subgroup_two_group_models['continuous_race']} continuous and {subgroup_two_group_models['binary_race']} binary targets. Exact subgroup counts, estimates and non-estimability reasons are reported in the Supplement; no formal between-group test, multiplicity correction or external validation was performed.")

# Replace the accumulated development-version Discussion with the concise,
# journal-facing structure used in the final manuscript.
discussion_heading_element = next(p._element for p in doc.paragraphs if p.text == "Discussion")
body_element = discussion_heading_element.getparent()
while (discussion_heading_element.getnext() is not None
       and discussion_heading_element.getnext().tag != qn("w:sectPr")):
    body_element.remove(discussion_heading_element.getnext())

doc.add_heading("Primary benchmark: continuous effects and stability", level=2)
doc.add_paragraph("The matched 8,241-patient, 1,933-pair benchmark is interpreted from target-level Q² or AUROC estimates, paired representation differences, alternative-partition variability, rank stability and grouped-versus-matched-random changes. The Q²≥0.20 and balanced-accuracy≥0.60 thresholds remain useful for catalogue navigation and workload prioritisation, but they are not inferential boundaries. Likewise, the former R1–R4 composite is retained only as a deprecated registry navigation tag and is not the biological hierarchy of the paper.")
doc.add_paragraph("Direct sequence-based examples illustrate the preferred reporting style. THYM–GTF2I mutation had AUROC 0.944/0.873/0.891 for TITAN/Giga-SSL/Prov-GigaPath and grouped AUROC 0.920/0.875/0.904; THCA–BRAF had 0.886/0.849/0.854 and grouped 0.900/0.836/0.857; LGG–IDH1 had 0.867/0.767/0.858 and grouped 0.829/0.751/0.855; and LGG–TP53 had 0.914/0.854/0.862 and grouped 0.898/0.843/0.857. COAD strict MSI similarly showed primary AUROC 0.931/0.874/0.882, but remains a sequence-derived genomic-context target rather than a clinically validated MSI assay. These estimates, their repeat distributions and grouped changes—not membership in a threshold class—motivate further locked evaluation.")
doc.add_paragraph("Derived immune programmes answer a different biological question. TGCT TGF-beta response showed agreement with a bulk-RNA signature (Q² 0.657/0.642/0.623; grouped Q² 0.604/0.470/0.461), TGCT leukocyte fraction with a methylation-derived estimate (0.467/0.440/0.425; grouped 0.393/0.372/0.402), and LIHC wound healing with a transcriptomic programme (0.402/0.219/0.293; grouped 0.306/0.214/0.222). The matched layer therefore measures agreement with these computational reference phenotypes; it does not establish analytical recovery of the originating RNA, methylation or deconvolution assay and does not directly enumerate immune cells. BLCA TIL Regional Fraction is same-H&E computational concordance and is not interpreted as cross-modal molecular prediction.")
doc.add_paragraph(f"Alternative partitions exposed instability that binary threshold labels concealed. The primary leading representation remained unchanged in all five alternatives for only {winner_stability('continuous')['all_five']}/{winner_stability('continuous')['tasks']} continuous and {winner_stability('binary')['all_five']}/{winner_stability('binary')['tasks']} binary pairs, while exactly-two and representation-specific threshold categories persisted in all five for only 33/136 continuous and 6/74 binary pairs combined. READ–APC and COAD–APC provide complementary grouped-partition warnings: both were strong under random folds but approached chance for at least two representations when complete tissue-source-site codes were separated. Translational interpretation therefore carries forward the continuous performance estimates, repeat rank and crossing proportion, sample-size stratum, grouped estimate and grouped-minus-matched-random change as separate fields rather than compressing them into an evidence grade.")
doc.add_paragraph(f"The targeted narrative mutation cross-check also limits claims of endpoint novelty: {len(prior_supported_mutations)}/{len(mutation_literature_audit)} screen-positive cancer–gene pairs had prior statistical support, two had previously been evaluated without support, and THYM–GTF2I was not identified in the reviewed predictive-model literature. Pooled colorectal reports were mapped to COAD and READ only when explicitly labelled as pooled evidence. Because one investigator performed a targeted PubMed and citation search without duplicate screening or formal risk-of-bias assessment, these counts describe the reviewed literature rather than a comprehensive systematic audit. The extended crosswalk and search method remain in the Supplement.")

doc.add_heading("Secondary TITAN layer: sensitivity to partitioning by TCGA tissue-source-site code", level=2)
doc.add_paragraph(f"Sensitivity to grouping by a barcode-derived cohort-structure variable changed the translational priority of several otherwise strong TITAN results: {ival(site_combined.get('below_threshold_models'))}/{ival(site_combined.get('screen_positive_models'))} candidates ({fnum(site_combined.get('below_threshold_percent'), 1)}%) fell below their original effect threshold. READ–APC changed from balanced accuracy {fnum(read_apc_site.get('random_balanced_accuracy'), 3)} to {fnum(read_apc_site.get('site_grouped_balanced_accuracy'), 3)}, and COAD–APC from {fnum(coad_apc_site.get('random_balanced_accuracy'), 3)} to {fnum(coad_apc_site.get('site_grouped_balanced_accuracy'), 3)}. Matched-random controls reduced the general penalty attributable to changed fold size and class balance, but the APC attenuations persisted and code alone predicted these outcomes. TCGA tissue-source-site code combines technical and biological case-mix information, so this analysis identifies sensitivity to grouping rather than proving technical confounding. Models with marked attenuation are explicitly warned and should not be prioritised solely from random-fold performance.")
doc.add_paragraph(
    f"The supporting TITAN-layer fold audit explains the previously reported 1–445-patient outer-test range. Five of 104 binary models had at least one single-class outer test fold, 25 had a single-class inner validation fold, and none had a single-class inner training fold; minimum outer training counts were 7 positive and 12 negative patients, and minimum inner training counts were 2 positive and 3 negative patients. Two of 219 continuous models used four outer folds. The sparse-fold flag applied to {titan_site_adequacy_by_outcome['binary']['models_with_sparse_grouped_folds']}/104 binary and {titan_site_adequacy_by_outcome['continuous']['models_with_sparse_grouped_folds']}/219 continuous TITAN models. Metrics were calculated from pooled outer out-of-fold predictions, not averages of fold-specific metrics."
)

doc.add_heading("Dependence on the downstream probe", level=2)
doc.add_paragraph(f"Pipeline ranking was probe dependent. In the completed binary atlas, each component count was evaluated by pooled inner out-of-fold AUROC, and the selected model produced the outer out-of-fold AUROC used for the primary representation comparison and the AUROC≥0.60 crossing summary. A balanced-accuracy operating point was learned only from the outer training data; sensitivity, specificity, balanced accuracy, PPV, NPV and PR-AUC complement the primary score metric. The matched empirical-prior and equal-prior calls remain operating-rule sensitivities. In the fixed {ival(probe_by_type['binary']['targets']) + ival(probe_by_type['continuous']['targets'])}-target algorithm comparison, changing from PLS to matched ridge retained the leading pipeline for {ival(probe_by_type['binary']['winner_retained'])}/{ival(probe_by_type['binary']['targets'])} binary and {ival(probe_by_type['continuous']['winner_retained'])}/{ival(probe_by_type['continuous']['targets'])} continuous targets. Paired intervals favoured ridge for {sum(r.get('outcome_type') == 'binary' for r in ridge_better)}/{len(ridge_binary)} binary and {sum(r.get('outcome_type') == 'continuous' for r in ridge_better)}/{len(ridge_continuous)} continuous targets and PLS for none. Under the primary 1-to-20-component grid, at least one outer fit selected component 20 for 14.6%, 12.9% and 12.0% of Giga-SSL, Prov-GigaPath and TITAN binary tasks; the corresponding continuous proportions were 0.2%, 0.5% and 0.1%. No numerical failure was recorded. The atlas therefore compares released embedding pipelines under the documented 1-to-20-component PLS-based probe and does not estimate each pipeline's best achievable performance under every linear head.")

doc.add_heading("Tertiary resource: translational role of the research interface", level=2)
doc.add_paragraph(f"PathoFMPred is a reproducible analysis and inference framework with a model registry; it is not a complete operationalization of every atlas crossing. The public MIT-licensed source package includes a small Giga-SSL fixture and user-invoked download functions for the permitted Giga-SSL and Prov-GigaPath collections. These collections contain {inventory_by_representation['GigaSSL']} and {inventory_by_representation['ProvGigaPath']} fitted objects, each covering the same {inventory_by_representation_outcome[('GigaSSL', 'continuous')]} continuous and {inventory_by_representation_outcome[('GigaSSL', 'binary')]} binary TITAN-qualified matched-cohort targets. Object presence is therefore separate from a representation-specific crossing: some stored objects did not cross, and some alternative-representation crossings have no stored object. The public package excludes the TITAN fitted collection. That collection remains in the private collaboration repository because the upstream TITAN terms classify models trained on TITAN outputs as derivatives and restrict redistribution. A generic builder lets an authorized user create a local object from independently obtained feature and outcome tables linked by a required patient identifier. Prediction and reporting return only cancer-specific endpoints that meet the recorded predictability rule unless the user explicitly requests audit records.")

doc.add_heading("Limitations", level=2)
doc.add_paragraph("All performance estimates are internal to TCGA, and no result establishes transportability, clinical utility, causal morphology or replacement of the originating molecular or computational assay. Tissue-source-site code is not a scanner or laboratory identifier; selection-conditioned intervals do not capture model selection or external sampling; some binary and continuous models have limited development denominators; equal slide pooling lacks tumour-area and independent pathology-quality weighting; and demographic subgroup estimates are sparse. Several immune targets are inferred signatures rather than direct cell measurements, while the global embeddings do not localise the supporting morphology. The fitted-object inventory covers only a defined subset of the atlas, and upstream representation licences limit which objects can be redistributed. These limitations make the resource a discovery-stage benchmark with a reproducible research interface and registry. Independent, locked evaluation with representative pathology quality control, compatible endpoint definitions and failure reporting is the necessary next step.")

doc.add_heading("Conclusions", level=1)
doc.add_paragraph("The primary contribution is a matched patient-level comparison of the released TITAN, Giga-SSL and Prov-GigaPath embedding pipelines under one common 1-to-20-component PLS-based probe. Direct genomic alterations, sequencing-derived burdens, inferred immune-cell fractions, transcriptomic signatures, RNA-derived pathway activities, composite scores and same-H&E quantities are reported as distinct label classes. Scientific conclusions rest on Q² or AUROC estimates, paired representation differences, alternative-partition variability and grouped-versus-matched-random changes. The crossing thresholds are pragmatic catalogue-navigation devices rather than inferential boundaries. Binary component selection, primary comparison and crossing status use an AUROC-centred estimand; PR-AUC and training-threshold sensitivity, specificity, balanced accuracy, PPV and NPV provide complementary information. No released pipeline was uniformly best, and this study does not estimate intrinsic foundation-model superiority or best-achievable performance under alternative linear heads. The supporting TITAN layer supplies deeper permutation/FDR and repeated-validation analyses for one representation. PathoFMPred operationalizes permitted fitted objects and records restricted ones separately, but creates no validation evidence. All estimates remain internal to TCGA; independent testing remains essential.")

doc.add_heading("Abbreviations", level=1)
doc.add_paragraph(
    "AUROC, area under the receiver operating characteristic curve; BA, balanced "
    "accuracy; CV, cross-validation; FDR, false discovery rate; H&E, "
    "haematoxylin and eosin; LDA, linear discriminant analysis; MC3, Multi-Center "
    "Mutation Calling in Multiple Cancers; MSI, microsatellite instability; OOF, "
    "out-of-fold; q-value, false-discovery-rate-adjusted p-value; SC interval, "
    "selection-conditioned patient-resampling interval for repeated out-of-fold predictions; "
    "PLS, partial least squares; Q², cross-validated coefficient of determination; RMSE, "
    "root-mean-square error; TCGA, The Cancer Genome Atlas; TCGA tissue-source-site code, "
    "barcode-derived submitting-centre field used as an internal cohort-structure variable."
)

doc.add_heading("Declarations", level=1)
for h, text in [
    ("Ethics approval and consent to participate", "We analysed publicly available, de-identified TCGA data. We recruited no participants and collected no new tissue."),
    ("Consent for publication", "Not applicable."),
    ("Study registration and protocol", "We did not prospectively register this retrospective computational benchmark."),
    ("Patient and public involvement", "We did not involve patients or members of the public in the design, conduct, interpretation or reporting of this secondary analysis."),
    ("Availability of data and materials", f"We used the official TITAN TCGA feature artifact, official Giga-SSL TCGA embeddings and the seandavis/tcga_provgigapath_embeddings Hugging Face dataset. The companion repository records conversion scripts, exact source locations, access conditions and SHA-256 checksums [30]. We do not redistribute controlled-access whole-slide images; the cited sources provide access to TCGA molecular data. We intend to archive the analysis code and synchronized complete-resolution result companions as a versioned release. After the authors approve and archive the exact submission snapshot, they must insert the final release tag, immutable commit and persistent DOI. These items remain blockers before acceptance, and the present working tree does not represent that archive. PathoFMPred source code is released under the MIT licence. The public package contains a minimal Giga-SSL fixture and offers explicit user-invoked downloads of the permitted Giga-SSL and Prov-GigaPath fitted collections, whose asset terms and upstream attribution are stated separately. The TITAN fitted collection is excluded from the public repository and retained only in the private collaboration repository pending written redistribution permission. Users may build a local object from independently obtained compatible representations and outcomes. None of the fitted objects is externally validated or intended for clinical use."),
    ("Competing interests", "Pending corresponding-author confirmation before submission. The analysis files do not contain a verified competing-interest declaration, so the statement cannot be completed without author input."),
    ("Funding", "Pending corresponding-author confirmation before submission. The analysis files do not identify verified funders, grant numbers or a no-specific-funding statement."),
    ("Authors’ contributions", "Pending approval by all authors before submission. A factual CRediT statement requires author confirmation of conceptualization, data curation, formal analysis, investigation, methodology, software, supervision, validation, visualization, writing and project-administration roles."),
    ("Acknowledgements", "OpenAI Codex assisted with code refactoring and language editing. Human authors remain responsible for verification, interpretation and the submitted text."),
]:
    doc.add_heading(h, level=2); doc.add_paragraph(text)

doc.add_heading("Additional files", level=1)
doc.add_paragraph(
    "Additional file 1: supplementary_material_JTM.docx. Contains Supplementary "
    "Methods, compact interpretive Tables S1-S18, Figures S1-S4 and an inventory "
    "of the synchronized machine-readable result companions."
)
doc.add_paragraph(
    "Additional file 2: Additional_file_2_COAD_example_A_PathoFMPred_report.pdf. COAD example A (TCGA-AA-A01F) complete PathoFMPred research-software output using TITAN, Giga-SSL and Prov-GigaPath features. "
    "The report lists every continuous and binary fitted model returned for each representation, with original predictions, class calls, internal TCGA reference ranks and model-performance metadata. It is a post hoc software illustration and is neither probability-calibrated nor externally validated."
)
doc.add_paragraph(
    "Additional file 3: Additional_file_3_COAD_example_B_PathoFMPred_report.pdf. COAD example B (TCGA-A6-A56B) complete PathoFMPred research-software output using TITAN, Giga-SSL and Prov-GigaPath features. "
    "The report lists every continuous and binary fitted model returned for each representation, with original predictions, class calls, internal TCGA reference ranks and model-performance metadata. It is a post hoc software illustration and is neither probability-calibrated nor externally validated."
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
f"30. Pathology foundation-model patient-level benchmark repository. GitHub. {REPO}. Accessed 20 Sep 2026.",
"31. International Agency for Research on Cancer. Global Cancer Observatory: GLOBOCAN 2022 world fact sheet. Lyon: IARC; 2024. https://gco.iarc.who.int/media/globocan/factsheets/populations/900-world-fact-sheet.pdf. Accessed 16 Aug 2026.",
f"32. PathoFMPred R package and fitted-model repository. GitHub. {MODEL_REPO}. Accessed 20 Sep 2026.",
"33. National Cancer Institute. Genomic Data Commons Cases API. https://api.gdc.cancer.gov/cases. Accessed 16 Aug 2026.",
"34. Fernandes G. Morpho-genomic deep learning for ovarian cancer subtype and gene mutation prediction from histopathology. arXiv. 2025;arXiv:2511.03365. doi:10.48550/arXiv.2511.03365.",
"35. Wells K, Lamrca A, Papaxoinis G, Wallace A, Quinn AM, Summers Y, Nonaka D. Unique correlation between GTF2I mutation and spindle cell morphology in thymomas (type A and AB thymomas). J Clin Pathol. 2023;76:463-466. doi:10.1136/jclinpath-2021-207837.",
"36. National Cancer Institute Clinical Proteomic Tumor Analysis Consortium. CPTAC-UCEC: The Clinical Proteomic Tumor Analysis Consortium Uterine Corpus Endometrial Carcinoma Collection. The Cancer Imaging Archive. doi:10.7937/K9/TCIA.2018.3R3JUISW. Accessed 20 Sep 2026.",
"37. Newman AM, et al. Robust enumeration of cell subsets from tissue expression profiles. Nat Methods. 2015;12:453–457. doi:10.1038/nmeth.3337.",
"38. Saltz J, et al. Spatial organization and molecular correlation of tumor-infiltrating lymphocytes using deep learning on pathology images. Cell Rep. 2018;23:181–193.e7. doi:10.1016/j.celrep.2018.03.086.",
"39. Lazard T, Lerousseau M, Decencière E, Walter T. Giga-SSL: self-supervised learning for gigapixel images. In: Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition Workshops. 2023. p. 4305–4314.",
"40. Xu H, et al. A whole-slide foundation model for digital pathology from real-world data. Nature. 2024;630:181–188. doi:10.1038/s41586-024-07441-w.",
"41. Lazard T, et al. Giga-SSL source code and released TCGA_encoded_t5e1000 embeddings. GitHub. https://github.com/trislaz/gigassl. Commit 605b950. Accessed 20 Sep 2026.",
"42. Davis S. TCGA Prov-GigaPath embeddings. Hugging Face Datasets. https://huggingface.co/datasets/seandavis/tcga_provgigapath_embeddings. Source snapshot commit 073115403c2fc5134ee8d1332c603edba591dddb. Accessed 20 Sep 2026.",
"43. Oquab M, Darcet T, Moutakanni T, et al. DINOv2: learning robust visual features without supervision. Trans Mach Learn Res. 2024. https://openreview.net/forum?id=a68SUt6zFt.",
"44. Goldman MJ, Craft B, Hastie M, et al. Visualizing and interpreting cancer genomics data via the Xena platform. Nat Biotechnol. 2020;38:675-678. doi:10.1038/s41587-020-0546-8.",
"45. Liberzon A, Birger C, Thorvaldsdottir H, Ghandi M, Mesirov JP, Tamayo P. The Molecular Signatures Database Hallmark Gene Set Collection. Cell Syst. 2015;1:417-425. doi:10.1016/j.cels.2015.12.004.",
]
for ref in references: doc.add_paragraph(ref)

# Final journal-facing condensation. The complete technical detail remains in
# the Supplement and synchronized machine-readable companions; the main paper
# retains only the information required to interpret the benchmark.
def _paragraph_exact(document, text):
    return next(p for p in document.paragraphs if p.text == text)


def _replace_block(document, start_text, end_text, builder):
    start = _paragraph_exact(document, start_text)._p
    end = _paragraph_exact(document, end_text)._p
    parent = start.getparent()
    node = start.getnext()
    while node is not None and node is not end:
        nxt = node.getnext()
        parent.remove(node)
        node = nxt
    marker = document.add_paragraph("__compact_block_marker__")._p
    builder()
    new_elements = []
    node = marker.getnext()
    while node is not None and node.tag != qn("w:sectPr"):
        nxt = node.getnext()
        new_elements.append(node)
        node = nxt
    marker.getparent().remove(marker)
    for element in new_elements:
        end.addprevious(element)


def _insert_before(document, target_text, builder):
    target = _paragraph_exact(document, target_text)._p
    marker = document.add_paragraph("__compact_insert_marker__")._p
    builder()
    new_elements = []
    node = marker.getnext()
    while node is not None and node.tag != qn("w:sectPr"):
        nxt = node.getnext()
        new_elements.append(node)
        node = nxt
    marker.getparent().remove(marker)
    for element in new_elements:
        target.addprevious(element)


def _replace_labelled(document, label, text):
    paragraph = next(p for p in document.paragraphs if p.text.startswith(label))
    for child in list(paragraph._p):
        if child.tag != qn("w:pPr"):
            paragraph._p.remove(child)
    run = paragraph.add_run(label)
    run.bold = True
    paragraph.add_run(text)


def _remove_paragraph_prefix(document, prefix):
    for paragraph in list(document.paragraphs):
        if paragraph.text.startswith(prefix):
            paragraph._p.getparent().remove(paragraph._p)


_replace_labelled(
    doc, "Methods.",
    f" A total of {foundation_common_n:,} patients across 30 The Cancer Genome Atlas (TCGA) cancer types and 3,389 cancer-endpoint pairs were analysed with TITAN, Giga-SSL and Prov-GigaPath representations. Multiple slides were mean-pooled within patients, and identical outcome subsets and nested patient-level folds were used with a common 1-to-20-component partial least-squares regression and linear discriminant classification pipeline. Cross-validated Q² and area under the receiver operating characteristic curve (AUROC) were used as primary metrics; Q² at least 0.20 and AUROC at least 0.60 summarized catalogue breadth. Stability was assessed with alternative partitions and grouping by TCGA tissue-source-site code. A supporting {n_patients:,}-patient TITAN screen across 32 cancers was evaluated with permutation and false-discovery-rate control."
)
_replace_labelled(
    doc, "Results.",
    f" Excluding 11 same-H&E tasks, TITAN, Giga-SSL and Prov-GigaPath crossed the Q² threshold in 633, 351 and 430 of 2,952 cross-modal continuous tasks. They crossed the AUROC threshold in {foundation_crossings('TITAN', 'binary')}, {foundation_crossings('GigaSSL', 'binary')} and {foundation_crossings('ProvGigaPath', 'binary')} of 426 binary tasks, including 137, 92 and 98 of 243 directly observed genomic-alteration tasks. Consensus signals included THYM-GTF2I mutation (AUROC 0.904, 0.884 and 0.893), strict COAD microsatellite instability (0.940, 0.851 and 0.857), UCEC fusion status (0.859, 0.661 and 0.705), the published TGCT TGF-beta Response signature (Q² 0.662, 0.647 and 0.601) and TGCT Hallmark TGF-beta signaling (0.519, 0.484 and 0.459), ordered as TITAN, Giga-SSL and Prov-GigaPath. No pipeline led every endpoint. In the supporting TITAN screen, grouping by tissue-source-site code moved {ival(site_combined.get('below_threshold_models'))} of {ival(site_combined.get('screen_positive_models'))} candidates below their original threshold and reduced COAD-APC and READ-APC performance towards chance."
)
_replace_labelled(
    doc, "Conclusions.",
    " Histology contained reproducible cross-pipeline signals for mutations, fusions, microsatellite instability, genomic context and derived inflammatory phenotypes. TITAN provided the broadest task-level coverage under this probe, while some endpoints favoured another representation. The atlas and PathoFMPred prioritize candidates for independent validation, but internal TCGA estimates and cohort-structure sensitivity preclude clinical use."
)
_remove_paragraph_prefix(doc, "Binary estimand sensitivity.")
_remove_paragraph_prefix(doc, "Sample-size strata.")

# Remove background material that is fully developed in the Supplement or the
# software documentation, retaining the gap, pipeline scope and study question.
for prefix in (
    "A practical feature of the fitted analysis is model portability.",
    "The study is organised as three linked but non-equivalent evidence layers.",
):
    _remove_paragraph_prefix(doc, prefix)


def _methods_study_design():
    doc.add_paragraph(
        f"A total of {n_slides:,} TITAN slides from {n_patients:,} patients, 11,427 Giga-SSL slides from 9,378 patients and 10,328 Prov-GigaPath slides from 8,393 patients were included in the released artifacts. In their union, 9,471 unique patients were identified. Of these, {foundation_common_n:,} (87.0%) were represented in all three datasets and were included in the matched benchmark. Analysis coverage is summarized in Supplementary Table S1, and participant characteristics by cancer are reported in Supplementary Table S2."
    )
    doc.add_paragraph(
        "Within each representation, eligible primary-tumour diagnostic slides were pooled by arithmetic mean before outcomes were joined. The patient, rather than the slide, was treated as the unit of analysis and cross-validation. Each patient with multiple slides was represented as one observation, and all slides from that patient were kept in the same fold."
    )
    doc.add_paragraph(
        f"No structured field for tumour cellularity, tissue area, artefact, biopsy/resection status or slide quality was provided by the available data. Generated TITAN slide narratives were used only for a non-adjudicated sensitivity audit. In the audit, 35 no-residual-tumour mentions were identified across six patients: TCGA-B6-A0IA and TCGA-B6-A0WV in BRCA, TCGA-55-8203 and TCGA-55-8507 in LUAD, TCGA-22-4596 in LUSC and TCGA-DX-AB2L in SARC. These patients were retained in the primary analysis because the generated narratives were derived from the same slides and did not constitute independent pathology review. In a post hoc sensitivity analysis, all six patients were removed before fold construction, and all {no_residual_sensitivity_total} screen-positive models in the four affected cancers were refitted using the documented nested-validation rules. A separate maximum-slide-count sensitivity was also conducted for TCGA-DX-AB2L, the participant represented by 30 SARC slides, by removal of this patient before fold construction and refitting of every SARC candidate. Molecular sources were linked at participant or 15-character sample-barcode level; identity of the tissue block, aliquot or tumour region is not proved by either linkage. Complete exclusion results and the full linkage, pathology-quality and pooling audits are reported in Supplementary Table S3."
    )


_replace_block(doc, "Study design, slides and patient unit", "Predictors and outcomes", _methods_study_design)


def _methods_predictors():
    doc.add_paragraph(
        "Slide vectors of 768 dimensions were supplied by TITAN and Prov-GigaPath, while 512-dimensional vectors were supplied by Giga-SSL. Five pragmatic inclusion criteria were applied. A ready-to-use slide-level TCGA embedding artifact had to be provided without downloading or reprocessing WSI pixels; deterministic slide identifiers linkable to patient and cancer had to be retained; one fixed-length whole-slide vector had to be provided; the 32-cancer frame had to be covered sufficiently for a common-patient analysis; and reproducible release metadata had to be provided for a materially distinct published whole-slide representation strategy. All five criteria were met by TITAN, Giga-SSL and Prov-GigaPath. Representative alternatives excluded because a compatible slide-level TCGA artifact, identifiers or common-cohort coverage were unavailable are listed in the supplementary inclusion audit; exclusion was not treated as a model-quality judgement. Upstream preprocessing, spatial resolution, training exposure and released layers were not harmonised. The estimand was therefore defined as complete released representation-pipeline performance under the common probe rather than intrinsic foundation-model quality. Because TCGA was used during Giga-SSL development, molecular labels were held out downstream although representation learning may have included the evaluated images."
    )
    doc.add_paragraph(
        "Outcome labels were acquired from published TCGA companion resources and were joined by the 12-character participant barcode after representation-specific patient vectors had been constructed. Where a 15-character TCGA sample barcode was supplied by a source, primary-tumour sample type 01 was first retained and eligible molecular rows were then collapsed to one participant-level outcome. Only a participant identifier was supplied by Thorsson. Source-specific and endpoint-specific missingness was retained. A participant absent from a molecular source was not assigned to the negative class. The same TCGA primary-tumour specimen is indicated by an exact 15-character sample match, but use of the same block, portion, analyte, aliquot, tumour region or subclone by the WSI and molecular assay is not proved. The source file, sheet, identifier, filtering, aggregation, missingness and transformation for every outcome group are reported in the supplementary endpoint dictionary and the machine-readable outcome_source_acquisition_map.csv."
    )
    doc.add_paragraph(
        "Immune, inflammatory and genomic-context features were obtained from the PanImmune_MS sheet of the Thorsson et al. supplementary workbook [19]. Fifty published non-survival, non-subtype and non-aggregate fields were selected, and their published participant-level values were imported rather than recalculated. These comprised 22 relative immune-cell fractions inferred from bulk RNA sequencing by CIBERSORT with the LM22 reference [37]; one methylation-derived leukocyte fraction; ten bulk-RNA expression signatures, including IFN-gamma response, TGF-beta response, wound healing, macrophage regulation, lymphocyte infiltration and Th1, Th2 and Th17 programmes; six BCR/TCR repertoire metrics; two somatic mutation rates; two in-silico neoantigen burdens; six genomic-context quantities; and the Saltz H&E-derived TIL Regional Fraction [38]. Endpoint-specific missing values were retained. The log1p transformation was applied only to silent and nonsilent mutation rates, SNV and indel neoantigen counts and number of segments; every other Thorsson value was used on its published scale. CIBERSORT fractions and inflammatory signatures were therefore interpreted as agreement with published computational reference phenotypes, not as measurements generated directly from the tissue."
    )
    doc.add_paragraph(
        "RNA pathway-activity outcomes were constructed from the batch-adjusted TCGA Pan-Cancer RNA-sequencing matrix downloaded from UCSC Xena [44] and the MSigDB 2026.1.Hs gene-set release [45]. Fifty Hallmark gene sets, the Reactome glutathione synthesis and recycling set and the Gene Ontology vitamin B6 metabolic-process set were used. Primary-tumour sample type 01 was retained, expression was averaged across multiple primary-tumour aliquots from the same participant, and genes were standardized within each cancer. Each pathway score was calculated as the mean standardized expression of its measured member genes. The scores are therefore RNA-derived computational reference phenotypes and not direct biochemical measurements of pathway flux, glutathione concentration or pyridoxine metabolism. Source URLs, checksums, gene-set membership and per-cancer measured-gene counts are reported in the supplementary source audit."
    )
    doc.add_paragraph(
        "Mutation labels were constructed from TCGA MC3 calls [24] accessed through the pinned TCGAmutations package, and tested genes were restricted to the tissue-specific driver catalogue in Bailey et al. Table S1 [25]. Primary-tumour samples, PASS variants and protein-altering missense, nonsense, nonstop, splice-site, translation-start, frameshift and in-frame changes were retained. COADREAD drivers were mapped to both COAD and READ. A participant was classified as mutated when a qualifying variant in the gene was present in any matched profiled primary sample. Wild type was assigned only when profiling of a primary-tumour sample was confirmed by MC3 clinical metadata and no qualifying variant was present; participants without an MC3-profiled primary tumour remained missing."
    )
    doc.add_paragraph(
        "Pathway status was imported from the Pathway level sheet of Sanchez-Vega et al. Table S4 [26]. Binary alterations in ten oncogenic signalling pathways are reported in the published matrix. Sample type 01 was retained, and a participant was defined as altered when any covered primary sample was altered in that pathway; participants absent from the table remained missing. The Taylor aneuploidy score, deleted-arm count, amplified-arm count and genome-doubling indicator were obtained from Table S2 [20]; continuous values were averaged across primary samples, and genome doubling was assigned when any primary sample was positive. Fusion calls and the assayed denominator were obtained from the two relevant sheets of Gao et al. Table S1 [21]; unique calls were collapsed by participant, zero was assigned only within the study sample list and fusion burden was log1p-transformed. Finally, MANTIS and MSIsensor fields were downloaded from the cBioPortal TCGA PanCancer Atlas clinical-sample files [22,23]; finite primary-sample scores were averaged, and missingness was retained when every primary-sample score was absent. A value greater than 0.4 was used for MSI-H in the main MANTIS definition; in the strict sensitivity, a value greater than 0.6 was used for MSI-H, a value less than 0.4 was used for MSS and intermediate scores were excluded."
    )


_replace_block(doc, "Predictors and outcomes", "PLS regression and PLS-LDA classification", _methods_predictors)


def _methods_models():
    doc.add_paragraph(
        "Each eligible cancer-endpoint pair was analysed as a separate cancer-specific task. In the matched benchmark, TITAN, Giga-SSL and Prov-GigaPath models were fitted independently while the same patients and validation folds were used. Features were centred within training folds by nested patient-level five-fold cross-validation, and 1 to 20 latent components were selected from pooled inner held-out predictions, with ties resolved in favour of fewer components. For continuous outcomes, PLS regression was fitted, inner root-mean-square deviation was minimised, and outer-fold Q², the cross-validated coefficient of determination, RMSE and Spearman correlation were evaluated. For binary outcomes, PLS-LDA was fitted, and the component count was selected by pooled inner out-of-fold (OOF) AUROC. The balanced-accuracy-maximising threshold from those inner training predictions was applied unchanged to the outer test fold. Outer OOF AUROC was evaluated as the primary paired statistic; PR-AUC, balanced accuracy, sensitivity, specificity, PPV and NPV were also reported. The observed outcome prevalence was used as the no-skill reference for PR-AUC. The discriminant score was uncalibrated and was not presented as a probability. At least 20 patients per class were required for binary eligibility, and at least 50 labelled patients were required for continuous eligibility."
    )
    doc.add_paragraph(
        "Seeded rSVD was used for every decomposition with the fastPLS 0.3 defaults. In the matched benchmark, identical outcome-labelled patients, folds, seeds and tuning rules were applied to all three representations. A descriptive effect-threshold crossing was defined as Q²≥0.20 for a continuous task or AUROC≥0.60 for a binary task. No representation-specific permutation or multiplicity procedure was applied in the matched benchmark, so effect-threshold crossings were treated as catalogue-navigation summaries rather than inferential discoveries. For all 426 matched binary pairs, the training-only optimized call was compared with empirical-prior and equal-prior calls on the identical AUROC-selected outer scores. Paired changes in balanced accuracy, sensitivity, specificity, PPV and NPV were reported. Symmetric folds and tuning objectives were used in the fixed 48-target ridge comparison, which was not treated as a second atlas."
    )


_replace_block(doc, "PLS regression and PLS-LDA classification", "Robustness and saved models", _methods_models)


def _methods_robustness():
    doc.add_paragraph(
        f"Five alternative nested partitions were run for {len(foundation_fold_selection)} effect-threshold-crossing or near-threshold pairs. Median effects, interquartile ranges, effect-threshold-crossing proportions, paired effect variability, leading-representation rank stability and threshold-derived support-pattern stability were calculated. All {foundation_union_counts['tasks']} pairs with an effect-threshold crossing in at least one representation were also rerun while complete TCGA tissue-source-site codes were held apart in outer and inner validation. Outer-fold sizes and binary class counts were preserved by matched-random controls. Each task metric was calculated once from all pooled patient-level outer out-of-fold predictions rather than by averaging fold-specific metrics. Predictions from a single-class outer test fold were included in the pooled task metric, but a stand-alone metric for that fold was not interpreted. The number of contributing codes, four- versus five-fold validation, minimum inner and outer training-class counts and single-class outer-test, inner-validation and inner-training indicators are recorded in the task-level audit. Fewer than five outer folds, outer test n below 10, a single-class binary fold or fewer than 20 patients in either binary training class are marked by a machine-readable sparse-fold warning. An unqualified robustness interpretation of a sparse grouped result is prevented by this warning; it is not an exclusion or validity threshold."
    )
    doc.add_paragraph(
        "For the component-range sensitivity, every selected component across the five outer fits, task-level and outer-fit ceiling frequencies, crossing changes, paired AUROC changes and representation-winner changes were reported. Five constant Giga-SSL dimensions were retained to preserve its released 512-feature schema; each constant column was mapped to zero by training-fold centering. No constant dimensions were present in TITAN or Prov-GigaPath, and no near-constant dimension with a full-cohort standard deviation between zero and 1e-8 was present in any representation. The sensitivity was failed closed on fitting errors, and no fallback estimator was used."
    )
    doc.add_paragraph(
        f"A total of 3,633 eligible pairs, comprising 3,174 continuous and 459 binary pairs, were evaluated in the supporting TITAN-only screen. Models below the effect checkpoint were assigned p=1 without permutation, while tests stopped after significance became impossible were assigned a distinct early-stopped p=1 status. Scaling, inner component selection, refitting and held-out prediction were repeated for every performed permutation. Up to 999 permutations were used in the primary audit, and eight separately locked leading targets were extended to 9,999 complete-process permutations with Monte Carlo intervals. Benjamini-Hochberg correction was applied within cancer and endpoint family; the q-value was defined as the false-discovery-rate-adjusted empirical p-value. Broader multiplicity sensitivities were reported separately. The {titan_candidate_total} qualified candidates were subjected to five additional nested partitions and grouping by TCGA tissue-source-site code. For highlighted candidates, patients from five fixed held-out prediction sets were resampled in the 95% selection-conditioned (SC) patient-resampling interval for repeated OOF predictions, and each metric was recalculated without folds being regenerated and without retuning or refitting. Patient sampling variation conditional on those fitted partitions is represented by the interval; it is not a confidence interval for external generalisation, and winner's-curse selection is not corrected. Complete permutation, Monte Carlo, uncertainty, fold-adequacy, class-size, continuous-reliability and multiple-slide details are reported in the Supplementary Methods and machine-readable audit files."
    )
    doc.add_paragraph(
        "Model coefficients, representation schema, outcome definition and internal-performance metadata are carried by PathoFMPred, but no validation evidence is created. Contributor-authored package source code and documentation are released under the MIT License. Permitted Giga-SSL and Prov-GigaPath fitted collections are provided as explicit, checksum-verified post-install downloads with separate asset notices and upstream attribution. TITAN-derived fitted parameters are excluded from the public repository because the upstream terms require permission for redistribution. Authorized users can construct and apply a local object with generic package functions. No independent cohort was evaluated."
    )


_replace_block(doc, "Robustness and saved models", "Software, transparency and validation status", _methods_robustness)


def _methods_software():
    doc.add_paragraph(
        "The analyses were performed in R 4.6.0 with fastPLS 0.3. Code, manifests, complete-resolution results and registries are contained in the companion repository. Representation sources, checksums, object access terms and the future locked-evaluation protocol are documented in the Supplement and software repository. No independent cohort was included, so every reported performance estimate remains internal to TCGA."
    )


_replace_block(doc, "Software, transparency and validation status", "Results", _methods_software)


def _compact_results():
    def _add_pathology_constraints_table():
        pathology_caption = doc.add_paragraph(
            "Table 2. Pathology-quality, pooling and molecular-slide linkage constraints. Linkage refers to the released identifier resolution. A shared 15-character TCGA sample barcode does not establish identity of the tissue portion, analyte, aliquot, block, tumour region or subclone."
        )
        pathology_caption.paragraph_format.keep_with_next = True
        pathology_table = add_table(
            doc,
            ["Area or endpoint source", "Available linkage or rule", "Observed extent", "Remaining limitation"],
            [
                ["Structured pathology quality", "Primary-tumour sample type and diagnostic-slide filename", "No structured tumour cellularity, tissue area, artefact, biopsy/resection or slide-quality field", "Slide eligibility and weighting were not pathology adjudicated"],
                ["Multiple diagnostic slides", "Arithmetic patient mean; slide weight 1/n within patient", f"{n_multi:,}/{n_patients:,} TITAN patients had more than one slide; maximum 30", "Prevents participant over-weighting and leakage but cannot ensure tumour representativeness"],
                ["Thorsson PanImmune", "Participant identifier only", f"{ival(linkage_by_source.get('Thorsson2018_PanImmune_MS', {}).get('covered_patients')):,} participant-linked patients", "The WSI and reference phenotype may derive from different tumour specimens"],
                ["Taylor aneuploidy", "15-character sample barcode", f"{ival(linkage_by_source.get('Taylor2018_TableS2', {}).get('exact_slide_sample_patients')):,}/{ival(linkage_by_source.get('Taylor2018_TableS2', {}).get('covered_patients')):,} exact sample matches", "Portion, analyte, aliquot, block and tumour region remain unresolved"],
                ["Sanchez-Vega pathways", "15-character sample barcode", f"{ival(linkage_by_source.get('SanchezVega2018_TableS4', {}).get('exact_slide_sample_patients')):,}/{ival(linkage_by_source.get('SanchezVega2018_TableS4', {}).get('covered_patients')):,} exact sample matches", "Portion, analyte, aliquot, block and tumour region remain unresolved"],
                ["Gao fusion calls", "15-character sample barcode", f"{ival(linkage_by_source.get('Gao2018_TableS1', {}).get('exact_slide_sample_patients')):,}/{ival(linkage_by_source.get('Gao2018_TableS1', {}).get('covered_patients')):,} exact sample matches", "RNA aliquot, block identity and within-tumour fusion heterogeneity remain unresolved"],
                ["cBioPortal MSI", "15-character sample barcode", f"{ival(linkage_by_source.get('cBioPortal_TCGA_PanCancer', {}).get('exact_slide_sample_patients')):,}/{ival(linkage_by_source.get('cBioPortal_TCGA_PanCancer', {}).get('covered_patients')):,} exact sample matches", "Molecular aliquot, slide block and tumour region remain unresolved"],
                ["MC3 mutation calls", "15-character sample barcode", f"{ival(linkage_by_source.get('TCGA_MC3_Bailey2018', {}).get('exact_slide_sample_patients')):,}/{ival(linkage_by_source.get('TCGA_MC3_Bailey2018', {}).get('covered_patients')):,} exact sample matches", "Portion, analyte, aliquot, block, region and subclone remain unresolved"],
            ],
            widths=[3.0, 3.7, 3.7, 4.6], font_size=6.3, header_font_size=6.6,
            line_spacing=1.0, fixed_layout=True,
        )
        for cell in pathology_table.rows[0].cells:
            shade(cell, "D9EAF7")

    doc.add_heading("Matched cohort and pipeline scope", level=2)
    doc.add_paragraph(
        f"We included {foundation_common_n:,} patients and 3,389 cancer–endpoint pairs shared across TITAN, Giga-SSL and Prov-GigaPath in the primary benchmark. These comprised 2,963 continuous and 426 binary pairs across 30 cancers. We used identical patients, outcomes, folds, seeds and tuning rules within each pair. Of the {ival(foundation_slide_audit.get('common_patients')):,} patients in this matched cohort, {ival(foundation_slide_audit.get('identical_slide_set_patients')):,} ({100 * ival(foundation_slide_audit.get('identical_slide_set_patients')) / ival(foundation_slide_audit.get('common_patients')):.1f}%) had exactly the same TCGA slide identifiers available in all three embedding datasets. At least one dataset lacked one or more otherwise eligible slides for the remaining {ival(foundation_slide_audit.get('common_patients')) - ival(foundation_slide_audit.get('identical_slide_set_patients')):,} patients. Restricting every pipeline to the {ival(foundation_slide_audit.get('exact_common_slides')):,} slides available in all three datasets left median performance changes near zero. The comparison nevertheless includes each pipeline's upstream preprocessing, resolution, representation-learning exposure and released layer."
    )
    doc.add_paragraph(
        "We analysed 768-dimensional TITAN, 512-dimensional Giga-SSL and 768-dimensional Prov-GigaPath whole-slide vectors. TITAN combined a CONCH v1.5 tile encoder with its region-of-interest workflow and released slide layer. Giga-SSL combined a ResNet-18 tile encoder with a sparse-convolutional slide encoder, while Prov-GigaPath combined a DINOv2-style tile encoder with its final long-context slide layer. The reported TITAN Mass-340K and Prov-GigaPath Providence pretraining corpora excluded TCGA. Giga-SSL development used TCGA, so direct exposure to evaluated slides cannot be excluded. All three downstream analyses withheld molecular labels. We therefore interpret every comparison as a result for the complete released representation pipeline rather than an image-unseen test of isolated foundation-model quality."
    )
    doc.add_paragraph(
        f"Pathology and molecular linkage limited interpretation. In the pathology-text exclusion sensitivity defined in Methods, the original threshold remained for {no_residual_threshold_retained_total}/{no_residual_sensitivity_total} models. All four highlighted affected models retained their thresholds; the largest absolute change was SARC Macrophage Regulation Q² from 0.520 to 0.472. This sensitivity does not replace independent pathology review."
    )
    doc.add_paragraph(
        "Supplementary Table S3 provides the patient-level generated-text audit, endpoint-level exclusion refits, source-specific linkage denominators and pooling diagnostics."
    )
    doc.add_paragraph(
        f"Pooling sensitivity supported the patient mean as a stable deterministic summary but did not establish tissue adequacy. Coordinate-wise median pooling changed the median Q² and balanced accuracy by {fnum_zero(median_pool_by_type.get('continuous', {}).get('median_delta'))} and {fnum_zero(median_pool_by_type.get('binary', {}).get('median_delta'))}; mean-versus-median ranks correlated {fnum(median_pool_by_type.get('continuous', {}).get('correlation_with_mean'))} and {fnum(median_pool_by_type.get('binary', {}).get('correlation_with_mean'))}, and {ival(median_pool_by_type.get('continuous', {}).get('retained_original_effect_threshold'))}/{len(median_pool_c)} continuous and {ival(median_pool_by_type.get('binary', {}).get('retained_original_effect_threshold'))}/{len(median_pool_b)} binary models retained their original thresholds. Among multi-slide patients, median pairwise cosine distances were {fnum(heterogeneity_by_model.get('TITAN', {}).get('median_pairwise_cosine_distance'), 3)}, {fnum(heterogeneity_by_model.get('GigaSSL', {}).get('median_pairwise_cosine_distance'), 3)} and {fnum(heterogeneity_by_model.get('ProvGigaPath', {}).get('median_pairwise_cosine_distance'), 3)} for TITAN, Giga-SSL and Prov-GigaPath; their 95th percentiles were {fnum(heterogeneity_by_model.get('TITAN', {}).get('q95_pairwise_cosine_distance'), 3)}, {fnum(heterogeneity_by_model.get('GigaSSL', {}).get('q95_pairwise_cosine_distance'), 3)} and {fnum(heterogeneity_by_model.get('ProvGigaPath', {}).get('q95_pairwise_cosine_distance'), 3)}. The median maximum leave-one-slide-out centroid changes were {fnum(heterogeneity_by_model.get('TITAN', {}).get('median_maximum_loo_centroid_distance'), 3)}, {fnum(heterogeneity_by_model.get('GigaSSL', {}).get('median_maximum_loo_centroid_distance'), 3)} and {fnum(heterogeneity_by_model.get('ProvGigaPath', {}).get('median_maximum_loo_centroid_distance'), 3)}. This was an embedding-level stability analysis, not a pathology or endpoint-performance adjudication."
    )
    doc.add_paragraph(
        f"In the maximum-slide-count sensitivity defined in Methods, the original threshold remained for {sum(float(r.get('exclusion_q2', 'nan')) >= 0.20 for r in sarc_exclusion_c)}/{len(sarc_exclusion_c)} continuous and {sum(float(r.get('exclusion_balanced_accuracy', 'nan')) >= 0.60 for r in sarc_exclusion_b)}/{len(sarc_exclusion_b)} binary models. IFN-gamma Response Q² changed from 0.233 to 0.183, Macrophages M0 from 0.211 to 0.163 and TP53 mutation balanced accuracy from 0.617 to 0.589. These threshold changes show why participant weighting and tissue representativeness are distinct problems."
    )
    add_figure(
        doc, "Figure1_patient_overlap_venn.png",
        "Figure 1. Patient and slide overlap across the three released TCGA representation datasets. TITAN contained 11,449 slides from 9,404 patients, Giga-SSL contained 11,427 slides from 9,378 patients and Prov-GigaPath contained 10,328 slides from 8,393 patients. The matched analysis used 8,241 patients. The exact common-slide intersection contained 10,165 slides, and 8,207 patients had identical slide sets across all three datasets. Region areas are schematic.",
        width=6.35,
    )

    doc.add_heading("Predictable tumour features and biological patterns", level=2)
    doc.add_paragraph(
        "The matched benchmark revealed its strongest and broadest biological signal in direct genomic alterations. At least one representation crossed the descriptive AUROC threshold in 160/243 mutation or fusion tasks, and all three crossed in 65/243. Composite genomic-context status, which included MSI, genome doubling and oncogenic-pathway states, crossed in at least one representation for 108/183 tasks and in all three for 57/183. The continuous layer was more selective: at least one representation crossed for 39/413 sequencing-derived burdens, 101/279 transcriptomic signatures, 31/638 computationally inferred immune-cell fractions and 35/166 continuous genomic-context scores. All three crossed for 10, 51, 13 and 11 tasks in these four classes. Figure 2 shows both the class-level breadth and named cancer-specific examples."
    )
    doc.add_paragraph(
        f"We first compared paired Q² and AUROC values without thresholding. Relative to TITAN, Giga-SSL effects had Spearman correlations of {fnum(foundation_pairwise_by_key[('GigaSSL versus TITAN', 'continuous')]['spearman_effect'])} for continuous tasks and {fnum(foundation_pairwise_by_key[('GigaSSL versus TITAN', 'binary')]['spearman_effect'])} for binary tasks; the corresponding Prov-GigaPath correlations were {fnum(foundation_pairwise_by_key[('ProvGigaPath versus TITAN', 'continuous')]['spearman_effect'])} and {fnum(foundation_pairwise_by_key[('ProvGigaPath versus TITAN', 'binary')]['spearman_effect'])}. Median alternative-minus-TITAN differences were {fnum(foundation_pairwise_by_key[('GigaSSL versus TITAN', 'continuous')]['median_delta_vs_TITAN'])} Q² and {fnum(foundation_pairwise_by_key[('GigaSSL versus TITAN', 'binary')]['median_delta_vs_TITAN'])} AUROC for Giga-SSL, and {fnum(foundation_pairwise_by_key[('ProvGigaPath versus TITAN', 'continuous')]['median_delta_vs_TITAN'])} Q² and {fnum(foundation_pairwise_by_key[('ProvGigaPath versus TITAN', 'binary')]['median_delta_vs_TITAN'])} AUROC for Prov-GigaPath. Figure 2 shows the complete paired distributions and makes clear that representation-specific estimates were correlated but not interchangeable."
    )
    if titan_prov_paired_by_outcome:
        tp_cont = titan_prov_paired_by_outcome["continuous"]
        tp_bin = titan_prov_paired_by_outcome["binary"]
        doc.add_paragraph(
            f"We also examined TITAN and Prov-GigaPath separately because their reported pretraining corpora excluded TCGA. For continuous tasks, both pipelines crossed Q² 0.20 in {ival(tp_cont['both_effect_threshold_crossing']):,}/2,963 pairs, TITAN alone crossed in {ival(tp_cont['TITAN_only_crossing']):,} and Prov-GigaPath alone in {ival(tp_cont['ProvGigaPath_only_crossing']):,}. TITAN had the higher Q² in {ival(tp_cont['TITAN_higher_effect']):,} pairs and Prov-GigaPath in {ival(tp_cont['ProvGigaPath_higher_effect']):,}; the median Prov-GigaPath-minus-TITAN difference was {fnum(tp_cont['median_delta_ProvGigaPath_minus_TITAN'], 3)} with a descriptive 95% cancer-cluster interval from {fnum(tp_cont['cluster_bootstrap_low'], 3)} to {fnum(tp_cont['cluster_bootstrap_high'], 3)}. For binary tasks, both crossed AUROC 0.60 in {ival(tp_bin['both_effect_threshold_crossing']):,}/426 pairs, TITAN alone in {ival(tp_bin['TITAN_only_crossing']):,} and Prov-GigaPath alone in {ival(tp_bin['ProvGigaPath_only_crossing']):,}. TITAN had the higher AUROC in {ival(tp_bin['TITAN_higher_effect']):,} pairs and Prov-GigaPath in {ival(tp_bin['ProvGigaPath_higher_effect']):,}; the median difference was {fnum(tp_bin['median_delta_ProvGigaPath_minus_TITAN'], 3)} ({fnum(tp_bin['cluster_bootstrap_low'], 3)} to {fnum(tp_bin['cluster_bootstrap_high'], 3)}). These cancer-cluster intervals describe paired task effects and are not confidence intervals for external generalisation. This comparison reduces one known difference in reported training exposure but still compares complete pipelines."
        )
    doc.add_paragraph(
        f"Catalogue-normalised summaries gave the same aggregate ordering but substantially different scales across outcomes. For continuous tasks, the task-level effect-threshold-crossing percentage, unique-definition percentage, macro-family percentage and macro-cancer percentage were {fnum(foundation_breadth_by_key[('TITAN', 'continuous')]['task_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('TITAN', 'continuous')]['endpoint_definition_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('TITAN', 'continuous')]['macro_family_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('TITAN', 'continuous')]['macro_cancer_crossing_percent'], 1)}% for TITAN, {fnum(foundation_breadth_by_key[('GigaSSL', 'continuous')]['task_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('GigaSSL', 'continuous')]['endpoint_definition_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('GigaSSL', 'continuous')]['macro_family_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('GigaSSL', 'continuous')]['macro_cancer_crossing_percent'], 1)}% for Giga-SSL and {fnum(foundation_breadth_by_key[('ProvGigaPath', 'continuous')]['task_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('ProvGigaPath', 'continuous')]['endpoint_definition_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('ProvGigaPath', 'continuous')]['macro_family_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('ProvGigaPath', 'continuous')]['macro_cancer_crossing_percent'], 1)}% for Prov-GigaPath. For binary tasks, the corresponding values were {fnum(foundation_breadth_by_key[('TITAN', 'binary')]['task_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('TITAN', 'binary')]['endpoint_definition_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('TITAN', 'binary')]['macro_family_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('TITAN', 'binary')]['macro_cancer_crossing_percent'], 1)}%, {fnum(foundation_breadth_by_key[('GigaSSL', 'binary')]['task_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('GigaSSL', 'binary')]['endpoint_definition_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('GigaSSL', 'binary')]['macro_family_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('GigaSSL', 'binary')]['macro_cancer_crossing_percent'], 1)}% and {fnum(foundation_breadth_by_key[('ProvGigaPath', 'binary')]['task_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('ProvGigaPath', 'binary')]['endpoint_definition_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('ProvGigaPath', 'binary')]['macro_family_crossing_percent'], 1)}/{fnum(foundation_breadth_by_key[('ProvGigaPath', 'binary')]['macro_cancer_crossing_percent'], 1)}%."
    )
    doc.add_paragraph(
        f"We defined a descriptive effect-threshold crossing as Q² at least 0.20 for a continuous task or AUROC at least 0.60 for a binary task. At least one representation produced an effect-threshold crossing for {foundation_union_counts['tasks']}/3,389 cancer-endpoint pairs ({100 * foundation_union_counts['tasks'] / 3389:.1f}%), including {foundation_union_counts['continuous']} continuous and {foundation_union_counts['binary']} binary pairs and covering {foundation_union_counts['unique_definitions']}/238 distinct feature definitions. Two or more representations produced an effect-threshold crossing for {foundation_two_counts['tasks']} pairs. All three did so for {foundation_all_three_counts['tasks']} pairs, including {foundation_all_three_counts['continuous']} continuous and {foundation_all_three_counts['binary']} binary pairs across {foundation_all_three_counts['unique_definitions']} distinct feature definitions. These counts depend on the endpoint catalogue, repeat correlated phenotypes across cancers and are not independent biological discoveries. The matched atlas has no representation-specific permutation or multiplicity testing."
    )
    doc.add_paragraph(
        "The cross-representation genomic core included GTF2I, BRAF, IDH1, TP53, ATRX, CIC, FGFR3, APC and PTEN mutations, any called fusion, MSI status, genome doubling and several oncogenic-pathway states. These associations concentrated in biologically recognisable cancer contexts. The glioma results linked histology to IDH1, TP53, ATRX and CIC alterations and to TP53, HIPPO, WNT and RTK-RAS pathway states. Thyroid carcinoma showed strong BRAF and RTK-RAS signals, thymoma showed a strong GTF2I signal, bladder carcinoma retained FGFR3, and endometrial cancer retained PTEN, TP53, fusion and genome-doubling signals. COAD and STAD retained both strict and broader MSI definitions."
    )
    doc.add_paragraph(
        f"Several direct or sequence-derived examples combined strong discrimination with agreement across representations and retention after tissue-source-site-code grouping. THYM GTF2I mutation reached AUROC {matched_binary_metric('TITAN', 'THYM', 'driver_mutation', 'GTF2I', 'auc')}/{matched_binary_metric('GigaSSL', 'THYM', 'driver_mutation', 'GTF2I', 'auc')}/{matched_binary_metric('ProvGigaPath', 'THYM', 'driver_mutation', 'GTF2I', 'auc')} for TITAN/Giga-SSL/Prov-GigaPath. THCA BRAF reached {matched_binary_metric('TITAN', 'THCA', 'driver_mutation', 'BRAF', 'auc')}/{matched_binary_metric('GigaSSL', 'THCA', 'driver_mutation', 'BRAF', 'auc')}/{matched_binary_metric('ProvGigaPath', 'THCA', 'driver_mutation', 'BRAF', 'auc')}, LGG TP53 reached 0.912/0.866/0.872 and LGG IDH1 reached 0.837/0.782/0.840. COAD strict MSI reached AUROC {matched_binary_metric('TITAN', 'COAD', 'microsatellite_instability_sensitivity', 'MSI-H strict (MANTIS >0.6)', 'auc')}/{matched_binary_metric('GigaSSL', 'COAD', 'microsatellite_instability_sensitivity', 'MSI-H strict (MANTIS >0.6)', 'auc')}/{matched_binary_metric('ProvGigaPath', 'COAD', 'microsatellite_instability_sensitivity', 'MSI-H strict (MANTIS >0.6)', 'auc')} and PR-AUC {matched_binary_metric('TITAN', 'COAD', 'microsatellite_instability_sensitivity', 'MSI-H strict (MANTIS >0.6)', 'pr_auc')}/{matched_binary_metric('GigaSSL', 'COAD', 'microsatellite_instability_sensitivity', 'MSI-H strict (MANTIS >0.6)', 'pr_auc')}/{matched_binary_metric('ProvGigaPath', 'COAD', 'microsatellite_instability_sensitivity', 'MSI-H strict (MANTIS >0.6)', 'pr_auc')}, compared with a prevalence and no-skill PR-AUC reference of {matched_binary_metric('TITAN', 'COAD', 'microsatellite_instability_sensitivity', 'MSI-H strict (MANTIS >0.6)', 'prevalence')}. Supplementary Table S4 reports the selected binary tumour-feature results."
    )
    doc.add_paragraph(
        "Fusion prediction produced a distinct set of results. Among 26 eligible binary fusion cancer-endpoint pairs, 12 crossed AUROC 0.60 with TITAN, 11 with Giga-SSL and 10 with Prov-GigaPath. Five crossed with all three representations: any called fusion in UCEC, LGG, THCA and BLCA, and TMPRSS2-ERG in PRAD. UCEC any called fusion was the strongest example, with 80 positive cases among 152 patients and AUROCs of 0.859, 0.661 and 0.705 for TITAN, Giga-SSL and Prov-GigaPath. THCA CCDC6-RET, with only 20 positive cases among 492 patients, reached 0.806 with TITAN and 0.627 with Giga-SSL but 0.567 with Prov-GigaPath. Continuous fusion burden crossed Q² 0.20 only for UCEC and LGG with TITAN, at 0.385 and 0.220; neither alternative representation crossed for fusion burden. These internally estimated signals prioritise cancer-specific fusion tasks for external testing rather than support one general fusion detector."
    )
    doc.add_paragraph(
        "The continuous results linked histology to selected inflammatory and tissue-context programmes rather than to every tested immune feature. All three representations captured TGCT TGF-beta response at Q² 0.662/0.647/0.601, THYM Th17 programme at 0.617/0.522/0.425, BLCA leukocyte fraction at 0.364/0.404/0.379, KIRP leukocyte fraction at 0.368/0.401/0.407 and THYM TCR diversity at 0.478/0.455/0.377 for TITAN/Giga-SSL/Prov-GigaPath. The shared set also included proliferation, macrophage regulation, lymphocyte-infiltration, Th1, TGF-beta and stromal-fraction signals in specific cancers. We treated these as agreement with bulk-transcriptomic, methylation-derived, repertoire or composite reference phenotypes rather than direct recovery of immune-cell abundance. All three representations also crossed all 11 same-H&E TIL Regional Fraction tasks, which we excluded from the default cross-modal summary. Supplementary Table S5 reports selected continuous results, Supplementary Table S6 summarizes predictability by feature family, and Supplementary Table S7 provides the literature context for each tumour-feature class."
    )
    add_figure(
        doc, "Figure2_biological_predictability_map.png",
        "Figure 2. Biological features predictable from the three released pathology representation pipelines. Panel A reports the number of eligible cancer-endpoint pairs reaching Q² at least 0.20 or AUROC at least 0.60 in at least one representation and in all three representations, after excluding the 11 same-H&E TIL-fraction tasks. Panel B shows selected direct genomic and genomic-context examples. Panel C shows selected immune, inflammatory and tissue-context reference phenotypes. Every displayed example crossed in all three representations and retained the threshold after tissue-source-site-code grouping. Points and numerical values follow the order TITAN, Giga-SSL and Prov-GigaPath. The coloured right-hand label identifies the pipeline with the highest observed effect for that pair. The selected examples span outcome classes and cancer contexts; the complete atlas reports every tested pair. Grouped retention is an internal cohort-structure sensitivity, not external validation.",
        width=6.35,
    )
    doc.add_paragraph(
        "The highest-performing representation differed by feature. TITAN led 14 of the 18 examples in Figure 2, including THYM GTF2I, COAD strict MSI, LGG TP53 mutation and pathway status, THCA BRAF, STAD MSI and several TGCT pathway activities. Prov-GigaPath led COAD genome doubling, THCA any called fusion and KIRP leukocyte fraction. Giga-SSL led the TGCT epithelial-mesenchymal-transition activity. Several margins were small, so we interpret close values as near-ties rather than evidence of a universally superior representation."
    )
    doc.add_paragraph(
        f"The operating-point audit used the same AUROC-selected scores for every rule. Counts with balanced accuracy at least 0.60 under empirical priors, equal priors and a training-only optimized threshold were "
        f"{ival(binary_operating_value('TITAN', 'empirical training priors', 'ba_crossings_for_sensitivity'))}/{ival(binary_operating_value('TITAN', 'equal class priors', 'ba_crossings_for_sensitivity'))}/{ival(binary_operating_value('TITAN', 'training-only optimized threshold', 'ba_crossings_for_sensitivity'))} for TITAN, "
        f"{ival(binary_operating_value('GigaSSL', 'empirical training priors', 'ba_crossings_for_sensitivity'))}/{ival(binary_operating_value('GigaSSL', 'equal class priors', 'ba_crossings_for_sensitivity'))}/{ival(binary_operating_value('GigaSSL', 'training-only optimized threshold', 'ba_crossings_for_sensitivity'))} for Giga-SSL and "
        f"{ival(binary_operating_value('ProvGigaPath', 'empirical training priors', 'ba_crossings_for_sensitivity'))}/{ival(binary_operating_value('ProvGigaPath', 'equal class priors', 'ba_crossings_for_sensitivity'))}/{ival(binary_operating_value('ProvGigaPath', 'training-only optimized threshold', 'ba_crossings_for_sensitivity'))} for Prov-GigaPath. "
        f"Relative to empirical priors, the training-only threshold changed median balanced accuracy by {fnum(binary_operating_value('TITAN', 'training-only optimized threshold', 'median_ba_delta_vs_empirical'), 3)}/{fnum(binary_operating_value('GigaSSL', 'training-only optimized threshold', 'median_ba_delta_vs_empirical'), 3)}/{fnum(binary_operating_value('ProvGigaPath', 'training-only optimized threshold', 'median_ba_delta_vs_empirical'), 3)}, sensitivity by {fnum(binary_operating_value('TITAN', 'training-only optimized threshold', 'median_sensitivity_delta_vs_empirical'), 3)}/{fnum(binary_operating_value('GigaSSL', 'training-only optimized threshold', 'median_sensitivity_delta_vs_empirical'), 3)}/{fnum(binary_operating_value('ProvGigaPath', 'training-only optimized threshold', 'median_sensitivity_delta_vs_empirical'), 3)}, specificity by {fnum(binary_operating_value('TITAN', 'training-only optimized threshold', 'median_specificity_delta_vs_empirical'), 3)}/{fnum(binary_operating_value('GigaSSL', 'training-only optimized threshold', 'median_specificity_delta_vs_empirical'), 3)}/{fnum(binary_operating_value('ProvGigaPath', 'training-only optimized threshold', 'median_specificity_delta_vs_empirical'), 3)}, PPV by {fnum(binary_operating_value('TITAN', 'training-only optimized threshold', 'median_ppv_delta_vs_empirical'), 3)}/{fnum(binary_operating_value('GigaSSL', 'training-only optimized threshold', 'median_ppv_delta_vs_empirical'), 3)}/{fnum(binary_operating_value('ProvGigaPath', 'training-only optimized threshold', 'median_ppv_delta_vs_empirical'), 3)} and NPV by {fnum(binary_operating_value('TITAN', 'training-only optimized threshold', 'median_npv_delta_vs_empirical'), 3)}/{fnum(binary_operating_value('GigaSSL', 'training-only optimized threshold', 'median_npv_delta_vs_empirical'), 3)}/{fnum(binary_operating_value('ProvGigaPath', 'training-only optimized threshold', 'median_npv_delta_vs_empirical'), 3)} for TITAN/Giga-SSL/Prov-GigaPath. "
        "Supplementary Table S8 summarizes the statistical and robustness audits, while complete paired changes for all five operating metrics remain machine readable. AUROC and PR-AUC did not change because the component and continuous outer score remained fixed. Table 1 summarizes descriptive predictability by tumour-feature class."
    )
    doc.add_paragraph(
        "Table 1. Tumour-feature classes with descriptive effect-threshold crossings. Percentages use eligible cancer-endpoint pairs within each class; values in brackets show distinct feature definitions. We evaluated some definitions in several cancers, so task counts are catalogue-dependent and do not represent independent biological discoveries."
    )
    table = add_table(
        doc,
        ["Tumour-feature class", "Eligible pairs", "Effect-threshold crossing in at least 1 representation, n/N (%) [features]", "Effect-threshold crossing in all 3 representations, n/N (%) [features]", "Examples represented in all 3"],
        [[label,
          predictable_feature_summary[(outcome, cls)]["eligible"],
          f"{predictable_feature_summary[(outcome, cls)]['union']}/{predictable_feature_summary[(outcome, cls)]['eligible']} ({100 * predictable_feature_summary[(outcome, cls)]['union'] / predictable_feature_summary[(outcome, cls)]['eligible']:.1f}%) [{predictable_feature_summary[(outcome, cls)]['unique_union']}]",
          f"{predictable_feature_summary[(outcome, cls)]['all_three']}/{predictable_feature_summary[(outcome, cls)]['eligible']} ({100 * predictable_feature_summary[(outcome, cls)]['all_three'] / predictable_feature_summary[(outcome, cls)]['eligible']:.1f}%) [{predictable_feature_summary[(outcome, cls)]['unique_all_three']}]",
          examples]
         for label, outcome, cls, examples in predictable_feature_classes],
        widths=[2.9, 1.3, 2.5, 2.5, 5.4], font_size=6.5, header_font_size=6.8,
        line_spacing=1.0, fixed_layout=True,
    )
    for cell in table.rows[0].cells:
        shade(cell, "D9EAF7")
    doc.add_paragraph(
        "Supplementary Table S9 documents endpoint provenance, derivation and assay-equivalence limitations. Table 2 summarizes pathology-quality, pooling and molecular-slide linkage constraints."
    )
    _add_pathology_constraints_table()
    doc.add_paragraph(
        f"Across all {len(foundation_crossmodal_union)} cross-modal cancer-endpoint pairs reaching the threshold in at least one representation, TITAN produced the highest observed Q² or AUROC for {foundation_leader_counts['TITAN']} ({100 * foundation_leader_counts['TITAN'] / len(foundation_crossmodal_union):.1f}%), Prov-GigaPath for {foundation_leader_counts['ProvGigaPath']} ({100 * foundation_leader_counts['ProvGigaPath'] / len(foundation_crossmodal_union):.1f}%) and Giga-SSL for {foundation_leader_counts['GigaSSL']} ({100 * foundation_leader_counts['GigaSSL'] / len(foundation_crossmodal_union):.1f}%). TITAN led most transcriptomic signatures, direct genomic alterations and both genomic-context classes. Prov-GigaPath contributed its largest relative share among sequencing-derived burdens, where it led {foundation_leader_by_feature_class[('continuous', 'sequencing-derived continuous burden')]['ProvGigaPath']}/38 pairs. Giga-SSL led {foundation_leader_by_feature_class[('binary', 'composite genomic-context score')]['GigaSSL']}/110 composite binary pairs, including selected RTK-RAS, cell-cycle and genome-doubling tasks. Figure 3 reports every feature-class distribution. These counts identify the highest observed internal estimate under the common PLS-based probe and do not test intrinsic foundation-model superiority."
    )
    add_figure(
        doc, "Figure3_foundation_model_leadership.png",
        "Figure 3. Foundation-model leadership by tumour-feature class. The analysis includes 960 cross-modal cancer-endpoint pairs that reached Q² at least 0.20 or AUROC at least 0.60 in at least one representation. Within each pair, the leading representation had the highest patient-level out-of-fold Q² for a continuous endpoint or AUROC for a binary endpoint under the common PLS-based probe. Numbers inside bars are pair counts. Small paired differences may represent near-ties, and the descriptive rank does not establish intrinsic model superiority or external transportability.",
        width=6.35,
    )
    doc.add_heading("Partition and probe sensitivity", level=2)
    doc.add_paragraph(
        f"Across five alternative matched partitions, an effect-threshold crossing recurred in all five for {foundation_crossing_stability_by_key[('TITAN', 'continuous')]['all_five']}/{foundation_crossing_stability_by_key[('TITAN', 'continuous')]['tasks']}, {foundation_crossing_stability_by_key[('GigaSSL', 'continuous')]['all_five']}/{foundation_crossing_stability_by_key[('GigaSSL', 'continuous')]['tasks']} and {foundation_crossing_stability_by_key[('ProvGigaPath', 'continuous')]['all_five']}/{foundation_crossing_stability_by_key[('ProvGigaPath', 'continuous')]['tasks']} continuous pairs for TITAN, Giga-SSL and Prov-GigaPath, respectively; the corresponding binary counts were {foundation_crossing_stability_by_key[('TITAN', 'binary')]['all_five']}/{foundation_crossing_stability_by_key[('TITAN', 'binary')]['tasks']}, {foundation_crossing_stability_by_key[('GigaSSL', 'binary')]['all_five']}/{foundation_crossing_stability_by_key[('GigaSSL', 'binary')]['tasks']} and {foundation_crossing_stability_by_key[('ProvGigaPath', 'binary')]['all_five']}/{foundation_crossing_stability_by_key[('ProvGigaPath', 'binary')]['tasks']}. Median between-partition standard deviations were {fnum(foundation_crossing_stability_by_key[('TITAN', 'continuous')]['median_effect_sd'])}/{fnum(foundation_crossing_stability_by_key[('GigaSSL', 'continuous')]['median_effect_sd'])}/{fnum(foundation_crossing_stability_by_key[('ProvGigaPath', 'continuous')]['median_effect_sd'])} Q² and {fnum(foundation_crossing_stability_by_key[('TITAN', 'binary')]['median_effect_sd'])}/{fnum(foundation_crossing_stability_by_key[('GigaSSL', 'binary')]['median_effect_sd'])}/{fnum(foundation_crossing_stability_by_key[('ProvGigaPath', 'binary')]['median_effect_sd'])} AUROC. The threshold-derived support class agreed with the primary class in at least four of five alternative partitions for {foundation_consensus_stability_overall['continuous']['at_least_four']}/{foundation_consensus_stability_overall['continuous']['tasks']} continuous and {foundation_consensus_stability_overall['binary']['at_least_four']}/{foundation_consensus_stability_overall['binary']['tasks']} binary pairs, and in all five for {foundation_consensus_stability_overall['continuous']['all_five']}/{foundation_consensus_stability_overall['continuous']['tasks']} and {foundation_consensus_stability_overall['binary']['all_five']}/{foundation_consensus_stability_overall['binary']['tasks']}. The primary leading representation persisted in all five for {winner_stability('continuous')['all_five']}/{winner_stability('continuous')['tasks']} continuous and {winner_stability('binary')['all_five']}/{winner_stability('binary')['tasks']} binary pairs. We therefore report support classes only as navigation tags and prioritise continuous effects, paired differences and rank stability."
    )
    doc.add_paragraph(
        f"We applied tissue-source-site-code grouping to all {foundation_union_counts['tasks']} pairs crossing in at least one representation. Of {len(foundation_tss_grouped):,} representation-task fits, {len(foundation_tss_feasible_rows):,} were estimable. ACC genome doubling was not estimable for any representation because one inner training partition contained a single class. Among pairs crossing in all three representations, every crossing retained its threshold for {foundation_tss_consensus_counts[('continuous', 'all three', 'complete retention')]}/{foundation_all_three_counts['continuous']} continuous and {foundation_tss_consensus_counts[('binary', 'all three', 'complete retention')]}/{foundation_all_three_counts['binary']} binary pairs. Median grouped-minus-matched-random effects were {fnum(foundation_tss_grouped_minus_matched('TITAN', 'continuous'), 3)}/{fnum(foundation_tss_grouped_minus_matched('TITAN', 'binary'), 3)} Q²/AUROC for TITAN, {fnum(foundation_tss_grouped_minus_matched('GigaSSL', 'continuous'), 3)}/{fnum(foundation_tss_grouped_minus_matched('GigaSSL', 'binary'), 3)} for Giga-SSL and {fnum(foundation_tss_grouped_minus_matched('ProvGigaPath', 'continuous'), 3)}/{fnum(foundation_tss_grouped_minus_matched('ProvGigaPath', 'binary'), 3)} for Prov-GigaPath. Grouping tests sensitivity to internal cohort structure; it does not provide institutional, scanner-level or external validation."
    )
    doc.add_paragraph(
        f"Grouped-fold adequacy was heterogeneous. Tasks contained {foundation_tss_code_min}-{foundation_tss_code_max} contributing codes; outer test sets ranged from {min(ival(r['minimum_outer_test_n']) for r in foundation_tss_fold_adequacy_summary)} to {max(ival(r['maximum_outer_test_n']) for r in foundation_tss_fold_adequacy_summary)} patients, and {sum(ival(r['tasks_with_four_outer_folds']) for r in foundation_tss_fold_adequacy_summary)} tasks used four rather than five folds. Among {foundation_tss_adequacy_by_outcome['binary']['tasks']} binary tasks, {foundation_tss_adequacy_by_outcome['binary']['tasks_with_single_class_outer_test_fold']} had a single-class outer test fold, {foundation_tss_adequacy_by_outcome['binary']['tasks_with_single_class_inner_validation_fold']} had a single-class inner validation fold and {foundation_tss_adequacy_by_outcome['binary']['tasks_with_single_class_inner_training_fold']} had a single-class inner training fold. Minimum outer training counts were {foundation_tss_adequacy_by_outcome['binary']['minimum_outer_training_positive']} positive and {foundation_tss_adequacy_by_outcome['binary']['minimum_outer_training_negative']} negative patients; minimum inner training counts were {foundation_tss_adequacy_by_outcome['binary']['minimum_inner_training_positive']} and {foundation_tss_adequacy_by_outcome['binary']['minimum_inner_training_negative']}. The sparse-fold warning applied to {foundation_tss_adequacy_by_outcome['binary']['tasks_with_sparse_grouped_folds']}/{foundation_tss_adequacy_by_outcome['binary']['tasks']} binary and {foundation_tss_adequacy_by_outcome['continuous']['tasks_with_sparse_grouped_folds']}/{foundation_tss_adequacy_by_outcome['continuous']['tasks']} continuous tasks. Metrics pooled all outer held-out predictions; we did not calculate or interpret a stand-alone AUROC for a single-class fold."
    )

    grouped_display_examples = [
        ("THYM-GTF2I", "binary", "driver_mutation", "THYM", "GTF2I"),
        ("THCA-BRAF", "binary", "driver_mutation", "THCA", "BRAF"),
        ("COAD strict MSI", "binary", "microsatellite_instability_sensitivity", "COAD", "MSI-H strict (MANTIS >0.6)"),
        ("READ-APC", "binary", "driver_mutation", "READ", "APC"),
        ("COAD-APC", "binary", "driver_mutation", "COAD", "APC"),
    ]

    def grouped_display_triplet(outcome, family, tumour, endpoint, field):
        return "/".join(
            fnum(foundation_effect_partition_map[
                (outcome, family, tumour, endpoint, model)
            ].get(field), 3)
            for model in ("TITAN", "GigaSSL", "ProvGigaPath")
        )

    def grouped_display_audit(outcome, family, tumour, endpoint):
        row = foundation_tss_adequacy_by_key[(outcome, family, tumour, endpoint)]
        flag = "sparse-fold warning" if row["grouped_fold_adequacy_flag"] == "sparse grouped folds" else "no audit trigger"
        return f"{row['n_codes']} codes; {row['realized_outer_folds']}/5 folds; {flag}"

    def alternative_partition_display(outcome, family, tumour, endpoint):
        values = []
        for short, model in (("T", "TITAN"), ("G", "GigaSSL"), ("P", "ProvGigaPath")):
            row = foundation_effect_partition_map[(outcome, family, tumour, endpoint, model)]
            values.append(
                f"{short} {fnum(row.get('repeat_effect_median'), 3)} "
                f"[{fnum(row.get('repeat_effect_q25'), 3)}-{fnum(row.get('repeat_effect_q75'), 3)}]; "
                f"crossing {fnum(row.get('crossing_proportion'), 2)}"
            )
        return "\n".join(values)

    def grouped_and_matched_display(outcome, family, tumour, endpoint):
        return (
            "Grouped " + grouped_display_triplet(outcome, family, tumour, endpoint, "grouped_effect") +
            "\nMatched-random " + grouped_display_triplet(outcome, family, tumour, endpoint, "matched_random_effect")
        )

    doc.add_paragraph(
        f"The separate, larger TITAN permutation/FDR screen showed the same concern under its documented balanced-accuracy rule: {ival(site_combined.get('below_threshold_models'))}/{ival(site_combined.get('screen_positive_models'))} candidates ({fnum(site_combined.get('below_threshold_percent'), 1)}%) fell below their original threshold. READ-APC declined from balanced accuracy {fnum(read_apc_site.get('random_balanced_accuracy'), 3)} to {fnum(read_apc_site.get('site_grouped_balanced_accuracy'), 3)}, and COAD-APC from {fnum(coad_apc_site.get('random_balanced_accuracy'), 3)} to {fnum(coad_apc_site.get('site_grouped_balanced_accuracy'), 3)}. In the separate matched-partition refits, grouped versus matched-random balanced accuracy was {fnum(site_control_apc.get(('READ', 'APC'), {}).get('grouped_metric'), 3)} versus {fnum(site_control_apc.get(('READ', 'APC'), {}).get('matched_random_metric'), 3)} for READ-APC and {fnum(site_control_apc.get(('COAD', 'APC'), {}).get('grouped_metric'), 3)} versus {fnum(site_control_apc.get(('COAD', 'APC'), {}).get('matched_random_metric'), 3)} for COAD-APC. TCGA tissue-source-site code alone achieved AUROC {fnum(site_control_apc.get(('READ', 'APC'), {}).get('code_only_metric'), 3)} and {fnum(site_control_apc.get(('COAD', 'APC'), {}).get('code_only_metric'), 3)}, respectively. These results support sensitivity to a barcode-derived cohort-structure variable, not proof of technical confounding or transportability."
    )
    doc.add_paragraph(
        f"Representation ordering depended on the downstream analysis. In the symmetric metadata-stratified sensitivity, ridge retained the PLS-leading representation for {ival(probe_by_type['binary']['winner_retained'])}/{ival(probe_by_type['binary']['targets'])} binary and {ival(probe_by_type['continuous']['winner_retained'])}/{ival(probe_by_type['continuous']['targets'])} continuous targets. The primary atlas therefore compares the released representations under the specified 1-to-20-component PLS-based probe. Selected-component distributions, ceiling selection and feature-variance checks are reported for every representation. The supporting TITAN permutation/FDR screen is reported separately and is not used to rank the three representations."
    )
    doc.add_paragraph(
        "Figure 4 shows the patient-level predictions behind one of the strongest shared continuous results. The published TGCT TGF-beta Response expression signature had the highest mean Q² among continuous cancer-endpoint pairs that crossed Q² 0.20 with all three representations. We plotted every held-out patient once for each representation, using the same observed reference values and the model-specific outer-fold prediction. This Thorsson signature is distinct from the separately modelled MSigDB Hallmark TGF-beta signaling score."
    )
    add_figure(
        doc, "Figure4_observed_vs_predicted_TGCT_TGFbeta.png",
        "Figure 4. Observed published TGCT TGF-beta Response values and patient-level out-of-fold predictions from TITAN, Giga-SSL and Prov-GigaPath. Each panel contains the same 148 patients. The dashed line marks perfect agreement and the coloured line shows the fitted linear trend. Q² was 0.662 for TITAN, 0.647 for Giga-SSL and 0.601 for Prov-GigaPath; the corresponding Spearman correlations were 0.788, 0.799 and 0.784. TGF-beta Response is a published RNA-expression signature from Thorsson et al., so the figure demonstrates internal agreement with a computational reference phenotype rather than recovery of a direct laboratory measurement or external validation.",
        width=6.35,
    )
    doc.add_heading("PathoFMPred outputs for two illustrative COAD patients", level=2)
    add_figure(
        doc, "Figure3_COAD_PathoFMPred_multifoundation_examples.png",
        "Figure 5. Post hoc PathoFMPred research-software illustration for TCGA-AA-A01F and TCGA-A6-A56B using TITAN, Giga-SSL and Prov-GigaPath inputs. Each panel includes only continuous endpoints predictable for that cancer and representation: 15 for TITAN, 12 for Giga-SSL and 14 for Prov-GigaPath. Corner labels give original predictions in source units. Radius gives the internal TCGA out-of-fold reference percentile, not a probability or clinical reference interval. The examples do not evaluate calibration, treatment response, external validation or clinical utility.",
        width=6.35,
    )
    doc.add_paragraph(
        "PathoFMPred applies only models that met the recorded predictability rule for the selected cancer and representation. Figure 5 illustrates this behaviour for two post hoc COAD examples. TITAN returned 15 predictable continuous endpoints per patient, Giga-SSL returned 12 and Prov-GigaPath returned 14. The differing radar axes are intentional: an endpoint is absent when the corresponding representation did not cross its threshold or when no eligible fitted object is available. The corners report original predictions in source units, while the radius uses an internal TCGA out-of-fold reference percentile only to place differently scaled outcomes on one display."
    )
    add_figure(
        doc, "Figure6_COAD_PathoFMPred_full_binary_output.png",
        "Figure 6. Complete predictable binary PathoFMPred output for the same two COAD examples using TITAN, Giga-SSL and Prov-GigaPath. The figure includes every binary endpoint returned for at least one representation: genome doubling; APC, KRAS and TP53 mutation status; broad and strict MANTIS-based MSI-H status; and MYC and TP53 pathway status. TITAN returned eight endpoints, while Giga-SSL and Prov-GigaPath returned seven each. Grey cells indicate that a representation did not return an eligible threshold-crossing fitted object. Each populated cell reports the direct class call, original uncalibrated LDA score and internal TCGA reference-score rank. Reference rank, not probability: raw LDA scores and ranks cannot be interpreted as calibrated probabilities or compared across models.",
        width=6.35,
    )
    doc.add_paragraph(
        "Figure 6 shows the complete binary output rather than a three-mutation subset. For TCGA-AA-A01F, all three representations called APC and TP53 mutation wild type; Giga-SSL alone called KRAS mutated and genome doubling present; TITAN and Prov-GigaPath called TP53 pathway status altered, while Giga-SSL called it unaltered. For TCGA-A6-A56B, all three called APC mutated; Giga-SSL and Prov-GigaPath called KRAS mutated; TITAN and Prov-GigaPath called TP53 mutation mutated; and all three called TP53 pathway status altered. Giga-SSL and Prov-GigaPath called genome doubling present in TCGA-A6-A56B, while TITAN called it absent. None of the six patient-representation combinations received an MSI-H call. TITAN alone returned a MYC pathway model and called both patients unaltered. Together, Figures 5 and 6 show every continuous and binary model that PathoFMPred returned for these COAD examples. The examples demonstrate the software interface and do not establish correctness, calibration, treatment response, external validity or clinical utility."
    )

_replace_block(doc, "Results", "Discussion", _compact_results)


def _compact_discussion():
    doc.add_paragraph(
        "The central biological result is a reproducible cross-representation set of cancer-specific histomolecular associations. Direct genomic alterations produced the broadest signal: at least one representation crossed in 160/243 tasks and all three crossed in 65. The strongest shared examples included THYM GTF2I, THCA BRAF, LGG TP53 and IDH1, BLCA FGFR3, UCEC fusion status, strict MSI in COAD and STAD, and genome-doubling or oncogenic-pathway states in several cancers. These results show that the embeddings retained histological information related to tumour lineage, genomic instability and pathway state, although the present analysis cannot identify the specific regions or cell patterns that generated each signal."
    )
    doc.add_paragraph(
        f"The comparison also provides a practical answer about representation choice. TITAN had the highest observed effect for {foundation_leader_counts['TITAN']}/{len(foundation_crossmodal_union)} cross-modal pairs reaching the threshold in at least one pipeline and led most of the selected high-performing biological examples. Prov-GigaPath nevertheless led {foundation_leader_counts['ProvGigaPath']} pairs, including LGG IDH1, KIRP leukocyte fraction and TGCT stromal fraction, while Giga-SSL led {foundation_leader_counts['GigaSSL']}, including BLCA FGFR3. Prov-GigaPath supplied its largest relative contribution among sequencing-derived burdens, whereas TITAN dominated the transcriptomic-signature group. These endpoint-specific results support selecting a representation for the intended tumour feature rather than choosing one pipeline for every task. Because small differences, alternative folds and a wider component grid changed some ranks, the atlas reports the full three-model estimates and their stability instead of assigning one universal winner."
    )
    doc.add_paragraph(
        "The continuous results add a complementary biological layer. Histology predicted selected inflammatory and tissue-context programmes, including TGF-beta response in TGCT and THCA, Th17 in THYM, lymphocyte-infiltration and Th1 signatures in THCA, proliferation in LUAD and THYM, leukocyte fraction in BLCA and KIRP, TCR diversity in THYM, and stromal fraction in TGCT and BLCA. The concentration of signal in particular cancer and feature combinations is more informative than an overall immune count. These models estimate agreement with CIBERSORT fractions, methylation-derived leukocyte estimates, RNA signatures, repertoire metrics or composite purity and stromal quantities. They do not recover a directly measured immune-cell count. We report the same-H&E TIL fraction separately as computational concordance."
    )
    doc.add_paragraph(
        f"Cohort structure and analytical choices materially affected prioritisation. When we held tissue-source-site codes apart, only {foundation_tss_consensus_counts[('continuous', 'all three', 'complete retention')]}/{foundation_all_three_counts['continuous']} continuous and {foundation_tss_consensus_counts[('binary', 'all three', 'complete retention')]}/{foundation_all_three_counts['binary']} binary pairs with effect-threshold crossings in all three representations retained every threshold. The primary threshold-derived support class agreed in all five alternative partitions for only {foundation_consensus_stability_overall['continuous']['all_five']}/{foundation_consensus_stability_overall['continuous']['tasks']} continuous and {foundation_consensus_stability_overall['binary']['all_five']}/{foundation_consensus_stability_overall['binary']['tasks']} binary pairs. Matched-random controls separate fold size and class balance from the additional grouped change. The expanded 1-20-component analysis retained the primary leader for 323/366 binary pairs and changed it for 43. Continuous effects, paired variability, ranks and grouped-minus-matched-random changes therefore carry more information than a hard threshold class."
    )
    doc.add_paragraph(
        f"The targeted narrative literature audit strengthens the biological credibility of the atlas: {len(prior_supported_mutations)}/{len(mutation_literature_audit)} TITAN screen-positive cancer-gene pairs recovered associations that previous histology-prediction studies had already supported statistically. We did not identify THYM-GTF2I in the reviewed predictive-model literature, which makes it a particularly interesting candidate for independent testing. Relative to earlier pan-cancer resources, including Arslan et al., we add a matched three-representation comparison, patient-first slide aggregation, explicit tested-negative results, and target-level partition and cohort-structure audits. PathoFMPred records compact linear model parameters without redistributing the original patient-level training embeddings, subject to upstream access and redistribution terms."
    )
    doc.add_paragraph(
        "Previous studies establish that the individual tumour-feature classes are biologically plausible prediction targets. Fu et al. predicted whole-genome duplication, chromosomal aneuploidies, driver alterations and tumour-composition signals [4]. Loeffler et al. compared gene and oncogenic-pathway prediction [8]. Dadhania et al. predicted ERG rearrangement in prostate cancer, and Mayer et al. predicted ALK and ROS1 fusions in lung cancer [9,10]. HE2RNA, regression-based biomarker studies and HistoTME predicted transcriptomic or tumour-microenvironment reference phenotypes [6,12,15], while Arslan et al. screened thousands of multi-omic biomarkers across the same 32 TCGA cancers [13]. Our principal innovation is the unified patient-level comparison of these feature classes across three released representation pipelines, with the same linear probe, explicit negative results and reusable representation-specific model records. The UCEC and LGG fusion-burden results and several cancer-specific any-fusion associations are less commonly reported tasks, but they still require an independent systematic literature review and external validation before any claim of endpoint novelty or clinical use."
    )
    doc.add_paragraph(
        "Independent validation is the next priority. Tissue-source-site code is a barcode-derived cohort variable rather than a scanner or institution identifier, so grouped retention cannot establish transportability. Our equal-weight pooling could not use tumour-area or independent pathology-quality weights; some molecular labels link only at participant or sample-barcode level; small outcome groups remain unstable; and global embeddings do not localise morphology. PathoFMPred currently supports research application and controlled model comparison. Researchers must test locked models in an independent, pathology-reviewed cohort with compatible endpoints and report all failures before considering clinical use."
    )


_replace_block(doc, "Discussion", "Conclusions", _compact_discussion)

# Short, non-repetitive conclusion.
conclusion_heading = _paragraph_exact(doc, "Conclusions")
conclusion_index = next(i for i, p in enumerate(doc.paragraphs) if p.text == "Conclusions")
conclusion_para = next(p for p in doc.paragraphs[conclusion_index + 1:] if p.text)
for child in list(conclusion_para._p):
    if child.tag != qn("w:pPr"):
        conclusion_para._p.remove(child)
conclusion_para.add_run(
    f"Under the common PLS-based probe, TITAN, Giga-SSL and Prov-GigaPath captured specific, cancer-dependent histological associations with mutations, fusions, MSI, genome doubling, oncogenic pathways and selected inflammatory or tissue-context phenotypes. At least one representation crossed the descriptive threshold for {foundation_union_counts['tasks']} cancer-endpoint pairs across {foundation_union_counts['unique_definitions']} feature definitions, and all three crossed for {foundation_all_three_counts['tasks']} pairs. "
    "THYM GTF2I, THCA BRAF, LGG IDH1 and TP53, BLCA FGFR3, COAD strict MSI, TGCT TGF-beta response, THYM Th17 and TCR diversity, and BLCA or KIRP leukocyte fraction provide concrete priorities for independent validation. "
    f"TITAN produced the highest observed effect for {foundation_leader_counts['TITAN']}/{len(foundation_crossmodal_union)} cross-modal threshold-crossing pairs, but Giga-SSL and Prov-GigaPath led important feature-specific subsets. Representation, partition and cohort structure still changed some estimates, so the atlas supports endpoint-specific model selection and biological prioritisation rather than one universal model, assay replacement or clinical validity. PathoFMPred provides a secondary route for applying compatible models in locked external research studies."
)

replace_reader_facing_chronology_terms(doc)
standardize_matched_evidence_terms(doc)
standardize_released_pipeline_terms(doc)
standardize_tissue_source_site_terms(doc)
standardize_sample_size_maturity_terms(doc)
standardize_literature_audit_terms(doc)
paired_figure_old = "Figure 2 shows the complete paired distributions and makes clear that representation-specific estimates were correlated but not interchangeable."
paired_figure_new = "Supplementary Figure S4 reports the complete paired distributions; representation-specific estimates were correlated but not interchangeable."
for paragraph in doc.paragraphs:
    if paired_figure_old not in paragraph.text:
        continue
    for run in paragraph.runs:
        if paired_figure_old in run.text:
            run.text = run.text.replace(paired_figure_old, paired_figure_new)

# Synchronize main-text references with the shortened Supplement. The former
# mutation-coverage table and TRIPOD+AI map were removed, and compact
# three-representation biological tables replaced the TITAN-only summaries.
compact_cross_reference_replacements = (
    ("Supplementary Tables S3a–S3d", "Supplementary Table S3"),
    ("Supplementary Tables S3a-S3d", "Supplementary Table S3"),
    ("Supplementary Table S15e", "Supplementary Table S10b"),
    ("Supplementary Table S18", "Supplementary Table S13"),
    ("Supplementary Table S17", "Supplementary Table S12"),
    ("Supplementary Table S15", "Supplementary Table S10"),
    ("Supplementary Methods and Tables S7-S10", "Supplementary Methods and Tables S4-S8"),
    ("compact interpretive Tables S1-S18", "compact interpretive Tables S1-S13"),
)
for text_node in doc.element.body.iter(qn("w:t")):
    if not text_node.text:
        continue
    for old, new in compact_cross_reference_replacements:
        text_node.text = text_node.text.replace(old, new)


def _audit_main_table_reference_order(document):
    """Fail the build if main or supplementary tables are first cited out of order."""
    # Only tables cited in the main manuscript are audited here. Later
    # supplementary tables are introduced sequentially inside Additional file 1.
    expected_supplementary = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
    first_supplementary = []
    first_main = []
    captions = []
    for paragraph in document.paragraphs:
        text_value = paragraph.text
        for label in re.findall(r"Supplementary Table S(\d+[a-z]?)", text_value):
            if label not in first_supplementary:
                first_supplementary.append(label)
        caption_match = re.match(r"Table ([123])\.", text_value)
        if caption_match:
            captions.append(caption_match.group(1))
            continue
        for label in re.findall(r"\bTable ([123])\b", text_value):
            if label not in first_main:
                first_main.append(label)
    if first_supplementary != expected_supplementary:
        raise RuntimeError(
            "Supplementary tables are first cited out of order: "
            + ", ".join("S" + label for label in first_supplementary)
        )
    if first_main != ["1", "2"] or captions != ["1", "2"]:
        raise RuntimeError(
            "Main tables are not cited and captioned in order: references="
            + repr(first_main)
            + ", captions="
            + repr(captions)
        )


_audit_main_table_reference_order(doc)
remove_em_dashes(doc)
doc.save(OUT / "manuscript_JTM_multifoundation_atlas.docx")


# Supplementary document
sup = setup(Document(), "Supplementary material - multi-foundation-model atlas")
sup.styles["Normal"].font.size = Pt(9.5)
sup.styles["Normal"].paragraph_format.line_spacing = 1.15
sup.styles["Normal"].paragraph_format.space_after = Pt(3)
for style_name in ("Title", "Heading 1", "Heading 2", "Heading 3"):
    sup.styles[style_name].paragraph_format.line_spacing = 1.15
sup.styles["Caption"].paragraph_format.line_spacing = 1.0
sup.styles["Caption"].paragraph_format.space_after = Pt(3)
sup.add_heading("Supplementary material", 0)
sup.add_paragraph(MANUSCRIPT_TITLE)
sup.add_paragraph("This document is Additional file 1, supplementary_material_JTM.docx. Additional_file_2_COAD_example_A_PathoFMPred_report.pdf and Additional_file_3_COAD_example_B_PathoFMPred_report.pdf contain the separate COAD research-software examples.")
sup.add_heading("Contents", 1)
sup.add_paragraph("The PDF retains interpretation-focused summaries. Complete target-level and per-model records reside in the synchronized CSV and RDS companions listed at the end. Word's Navigation pane links to every numbered heading.")
for item in ("Supplementary Methods: outcome acquisition, validation, reliability, literature and endpoint provenance",
             "Tables S1-S6: coverage, participant linkage, performance and software metadata",
             "Tables S7-S14: compact TITAN summaries, robustness, reporting and endpoint interpretation",
             "Tables S15-S18: matched three-representation, slide-set, normalized-breadth and provenance summaries",
             "Figures S1-S9: binary and continuous reliability, consensus, cohort-structure sensitivity, provenance-normalized breadth, paired representation effects, winner-rank stability and the post hoc PathoFMPred COAD illustrations",
             "Machine-readable companion inventory"):
    sup.add_paragraph(item, style="List Bullet")
sup.add_heading("Supplementary Methods", 1)
sup.add_paragraph("Reference numbers in this Supplement refer to the main-manuscript bibliography. The analysis used the established histology-prediction literature [1-16], PLS and discriminant-analysis methodology [17,18], published TCGA phenotype sources [19-26], false-discovery-rate and reporting guidance [27,28], the TCGA Clinical Data Resource [29], analysis and software repositories [30,32], global-incidence and GDC resources [31,33], targeted literature and planned external-cohort sources [34-36], immune-deconvolution and H&E TIL methods [37,38], the evaluated representation publications and released artifacts [39-42], DINOv2 as a general self-supervised vision example [43], UCSC Xena [44] and the MSigDB Hallmark collection [45].")
sup.add_paragraph("The executable analysis plan, source manifest, eligibility catalogues, checkpoint-capable scripts and released out-of-fold prediction tables are available in the public GPL-3.0-or-later companion analysis repository. PathoFMPred contributor-authored source code and documentation are released under the MIT License. The public package contains a minimal Giga-SSL fixture and explicit, checksum-verified post-install download functions for the permitted Giga-SSL and Prov-GigaPath fitted collections. Those assets carry separate notices and upstream attribution. The TITAN fitted collection is excluded from the public repository because redistribution requires upstream permission; authorized users can construct and apply a local object with the generic builder and object-level prediction function. Large local restart checkpoints and patient-level source data are not redistributed. Tables below are concise views; synchronized machine-readable files provide the complete-resolution companion records.")
sup.add_paragraph("For the selected cancer and representation, PathoFMPred prediction, plotting and reporting include only fitted objects that met the recorded predictability rule. In the matched atlas this is Q² at least 0.20 for continuous endpoints or AUROC at least 0.60 for binary endpoints. TITAN objects outside the three-representation common cohort retain the supporting permutation/FDR-qualified TITAN status. Smaller-sample crossings require explicit opt-in, while tested-below-threshold objects never enter prediction or reports and remain visible only in the raw audit registry.")
sup.add_paragraph("Terminology: predictability denotes held-out cross-validated statistical association under the specified model, folds, target definition and performance criterion. It does not denote causal biology, mechanistic interpretation, direct reconstruction of an assay, analytical or clinical equivalence, or permission to replace the originating measurement.")
sup.add_paragraph("Metric definitions: Q² is the cross-validated coefficient of determination; a q-value is a false-discovery-rate-adjusted empirical p-value; out-of-fold (OOF) denotes predictions generated for patients excluded from model fitting; a selection-conditioned (SC) interval is the patient-resampling interval calculated from the five fixed repeated OOF prediction sets; and TCGA tissue-source-site code is the barcode-derived submitting-centre field used as an internal cohort-structure variable.")
sup.add_paragraph("Representation-artifact audit: the downloaded Prov-GigaPath Parquet contained 1,406 excess rows across 1,402 duplicated slide identifiers. The repeated final-layer vectors were exactly identical. Conversion retained the first occurrence and removed all 1,406 exact duplicate Prov-GigaPath rows before slide filtering and patient pooling, so repeated source rows could not alter slide or patient weights. The source dataset card does not document why the duplicate rows were present.")
sup.add_heading("Outcome acquisition, participant linkage and label construction", 2)
sup.add_paragraph("The published supplementary workbooks or public TCGA PanCancer files identified below were downloaded, and values were imported with the source-specific rules implemented in R/02_build_nonmutation_targets.R and R/03_build_mutation_targets.R. Outcomes were joined after slide pooling. A 12-character TCGA participant barcode was used for every analysis row, and 15-character sample barcodes were retained when supplied by the source. Source absence was treated as missing rather than negative. The exception was a documented assayed denominator: MC3-profiled patients without a qualifying mutation and Gao study samples without a fusion call were assigned negative according to the rules below. Filenames, DOI identifiers and SHA-256 digests are recorded in the source manifest; cancer-specific denominators are reported in molecular_source_coverage_audit.csv and mutation_coverage_audit.csv.")
for source_row in outcome_source_acquisition:
    add_labelled(
        sup,
        source_row["source"] + ".",
        " " + source_row["label_domains"] + " Source: " +
        source_row["local_source"] + " (" + source_row["publication_reference"] +
        "). Identifier: " + source_row["source_identifier"] +
        ". Processing: " + source_row["input_processing"] +
        ". Participant rule: " + source_row["participant_aggregation"] +
        ". Missing or negative rule: " + source_row["missing_or_negative_rule"] +
        ". Transformation: " + source_row["analysis_transformation"] + "."
    )
sup.add_heading("Binary class-size, fold-composition and stability analyses", 2)
sup.add_paragraph("The primary screening estimate is the initial nested-CV value used for candidate selection and permutation testing. The repeated-validation estimate is the mean across five additional independently seeded nested-CV partitions and is reported as a post-selection stability estimate. The values need not be identical because the fold partitions and rSVD seeds differ. The supporting screen retained a minimum of 20 positive and 20 negative participants so that rare cancer-specific endpoints were not silently discarded; a separate 50-per-class analysis was used only as a sample-size sensitivity. For all 99 binary candidates, every repeated outer fold and the corresponding inner partitions used to select 1 to 20 components were audited for class counts. Component distributions summarize the 25 outer fits generated by five repeats of five-fold nested validation. PR-AUC is non-interpolated average precision; PPV and NPV use held-out calls and the observed TCGA prevalence and are not calibrated or transportable probabilities.")
sup.add_paragraph("Prediction stability used standardized held-out LDA scores because independently fitted discriminant scales are not directly comparable. For each pair of repeats, Spearman correlation was calculated over patient scores and agreement over class calls, then averaged. Limited-evidence learning curves used the original outer test fold at every fraction and fitted the model to deterministic stratified 50%, 75% and 100% subsets of that fold's training patients. The full-data point exactly reproduces the original repeated nested-CV result. Small-class screen-positive models remain in the complete analysis registry but are excluded from default PathoFMPred inference; an explicit include_limited_evidence=TRUE opt-in emits a warning.")
sup.add_heading("Continuous sample-size and stability audit", 2)
sup.add_paragraph("For all 770 continuous TITAN candidates, the outcome-labelled sample size, five-repeat Q² distribution and patient-level prediction stability were summarized. Stability was the mean of all ten pairwise Spearman correlations between the five repeated out-of-fold prediction vectors. The deterministic seed schedule was rerun to persist the component selected in each of 25 outer fits per target. A 20-component selection was recorded as reaching the fixed search ceiling. Ninety-one models had fewer than 100 labelled patients and were assigned to the smaller sample-size stratum; the corresponding binary stratum contained 19 models with fewer than 50 patients in one class. These descriptive cutoffs do not change eligibility, screening, multiplicity or the complete atlas and are not evidence grades.")
sup.add_heading("Targeted narrative literature audit", 2)
sup.add_paragraph("A targeted narrative audit rather than a systematic review was conducted. PubMed was last searched on 24 August 2026 with: (1) ‘(histology OR H&E OR whole-slide image) AND (mutation OR genomic alteration) AND (prediction OR deep learning) AND cancer’; (2) ‘(computational pathology OR digital pathology) AND molecular biomarker prediction AND cancer’; (3) ‘pan-cancer AND histology AND mutation prediction AND TCGA’; and (4) ‘thymoma AND GTF2I AND (histology OR morphology OR prediction)’. Backward and forward citations of the principal pan-cancer and endpoint-specific reports were checked, and primary-study supplementary tables were inspected when available.")
sup.add_paragraph("Human tumour studies were included when they predicted a mutation or molecular feature from routine histological whole-slide images and reported a cancer–endpoint result mappable to the present atlas. Morphology-only associations without a predictive model, non-histological predictors, prognosis-only studies, reviews without primary performance estimates and non-mappable targets were excluded. Preprints were retained in a separate preliminary-evidence category. A pooled colorectal/CRC result was mapped to both COAD and READ but retained the scope label ‘pooled colorectal’; exact COAD or READ evidence took precedence. One investigator screened and extracted the study, cancer, endpoint, metric, statistical-support status, cohort scope and source URL. There was no duplicate independent screening, protocol registration or formal risk-of-bias assessment. Accordingly, ‘not identified’ means not found in this targeted cross-check and is not a claim of bibliographic novelty. The machine-readable method and pair-level decisions are literature_crosscheck_method.csv and supported_mutation_literature_audit.csv.")
sup.add_heading("Endpoint provenance and qualitative morphology context", 2)
sup.add_paragraph("Every eligible cancer-endpoint target was assigned a label-generation class before interpretation: directly observed genomic alteration, sequencing-derived continuous burden, computationally inferred immune-cell fraction, transcriptomic signature, pathology-associated quantity or composite genomic-context score. The machine-readable endpoint_dictionary.csv contains one row for every target, including source modality, direct or inferred status, derivation algorithm, original scale, analysis transformation, missingness, expected measurement error, biological interpretation and an assay-equivalence caveat. endpoint_definition_dictionary.csv collapses these rows to unique endpoint definitions. TIL Regional Fraction alone is flagged as a same-H&E-modality target.")
sup.add_paragraph("For the morphology-context sensitivity, five models were selected to represent different label modalities rather than to imply exhaustive interpretability. High and low anchors were restricted to report-covered concordant extremes of mean repeated out-of-fold predictions. Their nearest within-cancer neighbours were selected by cosine similarity of patient-level mean TITAN representations within the corresponding high/low prediction stratum. A representative report-covered slide was chosen by minimum squared distance to the patient mean. Exact prediction values and ranks were retained without dichotomising continuous outputs. A fixed term list and excerpts were extracted from TITAN-generated slide reports only for contextual audit. This analysis cannot localise patches or support causal morphology because tile representations, pixels and independent blinded pathology annotations were unavailable.")
sup.add_heading("Secondary comparison of single-outcome and multi-outcome PLS", 2)
sup.add_paragraph("The documented secondary comparison jointly modelled three inflammatory blocks: infiltration/signatures, immune repertoire and inferred immune-cell fractions. Separate single-outcome PLS models and joint multi-outcome PLS used identical complete-case patients and outer folds, training-fold outcome scaling, separately selected component counts and three independently seeded nested-CV repeats. Changes in Q² were aggregated first within cancer; uncertainty was estimated by resampling cancers. Endpoint win counts were not treated as inferential evidence. Multi-outcome PLS was not substituted into the main resource because it applies only to coherent continuous panels, requires the intersection of patients with every response observed, shares a latent representation across a fixed ordered response set and changes the estimand from one endpoint to a joint panel. It cannot replace the individual binary PLS-LDA models. Its positive average results motivate a future multi-outcome immune resource whose evaluation rules should be committed before outcome inspection, but no external validation or matched multi-outcome ridge baseline was available.")
sup.add_heading("Table S1. Analysis coverage", 1)
sup.add_paragraph("Screening tier A and tier B are retained only as database-navigation tags for the documented effect thresholds. They are not clinical, biological or statistical evidence grades.", style="Caption")
add_table(sup, ["Family", "Type", "Tests", "Cancers", "Screening tier A", "Screening tier B", "Screen-negative"], family_table)
sup.add_heading("Table S1a. Analysis chronology", 1)
sup.add_paragraph("The study was not prospectively registered. The analysis plan first appears in the initial repository snapshot, which also contains completed results; that commit documents the plan but cannot establish that it preceded inspection of those results. ‘Locked before running’ is reserved for analyses with a separate pre-result commit.")
add_table(
    sup,
    ["Category", "Analysis or rule", "Timing relative to results", "Repository evidence / date", "Manuscript terminology"],
    [(r.get("category"), r.get("analysis_or_rule"), r.get("timing_relative_to_results"),
      f'{r.get("repository_evidence")} / {r.get("date")}', r.get("terminology_in_manuscript"))
     for r in analysis_chronology],
    [2.5, 5.0, 5.0, 3.5, 4.0],
)
sup.add_heading("Table S1b. Screen-positive TITAN-layer candidates by cancer", 1)
candidate_counts_by_cancer = {}
for r in supported_c:
    candidate_counts_by_cancer.setdefault(r.get("tumor_type"), [0, 0])[0] += 1
for r in supported_b:
    candidate_counts_by_cancer.setdefault(r.get("tumor_type"), [0, 0])[1] += 1
add_table(
    sup,
    ["Cancer", "Continuous candidates", "Binary candidates", "Total candidates"],
    [(cancer, counts[0], counts[1], counts[0] + counts[1])
     for cancer, counts in sorted(candidate_counts_by_cancer.items())],
    [3.0, 3.2, 3.0, 3.0],
)
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
if subgroup_performance:
    sup.add_heading("Table S2b. Sex- and broad race-stratified performance denominators", 1)
    sup.add_paragraph(f"The complete machine-readable subgroup_performance_audit.csv reports all {titan_candidate_total} screen-positive models and every subgroup-specific metric or reason for non-estimability. This concise table gives exact counts for highlighted models. Recorded sex is derived from the TCGA CDR gender field. Binary counts are shown as n (positive/negative); continuous counts are n. Performance was estimated only for high-volume models (n≥200) with ≥50 patients per continuous subgroup or ≥20 positive and ≥20 negative patients per binary subgroup. These post hoc estimates reuse fixed held-out predictions and are not fairness validation.")
    subgroup_by_model = {}
    for r in subgroup_performance:
        if r.get("highlighted") != "TRUE":
            continue
        key = (r.get("outcome_type"), r.get("family"), r.get("tumor_type"), r.get("endpoint"), r.get("model_n"))
        subgroup_by_model.setdefault(key, {})[(r.get("subgroup_variable"), r.get("subgroup"))] = r
    subgroup_table_rows = []
    for key, values in sorted(subgroup_by_model.items()):
        outcome_type, family, cancer, endpoint, model_n = key
        def count_text(variable, subgroup):
            row = values.get((variable, subgroup))
            if not row:
                return "0"
            if outcome_type == "binary":
                return f'{row.get("subgroup_n")} ({row.get("positive")}/{row.get("negative")})'
            return str(row.get("subgroup_n"))
        estimable = [r.get("subgroup") for r in values.values() if r.get("denominator_adequate") == "TRUE"]
        subgroup_table_rows.append((
            outcome_type, cancer, f'{endpoint} [{family.replace("_", " ")}]', model_n,
            f'{count_text("Recorded sex", "FEMALE")}/{count_text("Recorded sex", "MALE")}/{count_text("Recorded sex", "Missing")}',
            f'{count_text("Broad race", "White")}/{count_text("Broad race", "Black or African American")}/{count_text("Broad race", "Asian")}/{count_text("Broad race", "Other recorded race")}/{count_text("Broad race", "Missing")}',
            ", ".join(estimable) if estimable else "None: denominator rule not met"
        ))
    add_table(sup, ["Type", "Cancer", "Endpoint", "n", "Sex F/M/missing", "Race W/B/A/O/missing", "Subgroups with performance"], subgroup_table_rows)
sup.add_heading("Table S3. Slide multiplicity and report coverage by cancer", 1)
add_table(sup, ["Cancer", "Patients", "Slides", "Multi-slide patients", "Maximum slides", "Multiple primary barcodes", "Exact report matches"],
          [(r.get("tumor_type") or "Unresolved", r.get("patients"), r.get("eligible_slides"),
            r.get("multi_slide_patients"), r.get("maximum_slides_per_patient"),
            r.get("patients_with_multiple_primary_sample_barcodes"), r.get("exact_report_matched_slides"))
           for r in slide_multiplicity])
if pathology_qc_fields:
    sup.add_heading("Table S3b. Pathology quality-control field availability", 1)
    sup.add_paragraph(
        "This audit distinguishes structured metadata from unvalidated mentions in TITAN-generated narrative text. "
        "Narrative mentions were counted for transparency only and did not define exclusions, weights or outcomes. "
        f"The maximum-slide participant was {maximum_slide_patient.get('patient')} ({maximum_slide_patient.get('project_id')}), "
        f"with {maximum_slide_patient.get('n_slides')} slides weighted {fnum(maximum_slide_patient.get('within_patient_slide_weight'))} each within its patient mean; "
        f"all {maximum_slide_patient.get('narrative_no_residual_tumour_slides')} generated narratives mentioned no residual sarcoma/myxofibrosarcoma."
    )
    add_table(
        sup,
        ["Domain", "Structured field", "Field/evidence", "Interpretation"],
        [(r.get("domain"), r.get("structured_field_available"),
          r.get("field_or_evidence") or "—", r.get("interpretation"))
         for r in pathology_qc_fields],
    )
    sup.add_paragraph(
        f"Narrative audit among {ival(pathology_qc.get('exact_report_matched_slides')):,} exact report matches: "
        f"tumour-content mentions {ival(pathology_qc.get('tumour_content_mentions'))}; tissue-area mentions "
        f"{ival(pathology_qc.get('tissue_area_mentions'))}; artefact mentions {ival(pathology_qc.get('artefact_mentions'))}; "
        f"procedure mentions {ival(pathology_qc.get('procedure_mentions'))}; explicit slide-quality mentions "
        f"{ival(pathology_qc.get('slide_quality_mentions'))}; no-residual-tumour mentions "
        f"{ival(pathology_qc.get('no_residual_tumour_mentions'))} slides from {ival(no_residual_patient_summary.get('flagged_patients'))} patients. "
        "Complete slide-multiplicity and audit outputs are in pathology_qc_patient_multiplicity_audit.csv, "
        "pathology_qc_narrative_audit.csv, pathology_qc_no_residual_patient_audit.csv and pathology_qc_maximum_slide_patient.csv."
    )
    sup.add_paragraph("Panel B. Patients carrying a generated no-residual-tumour narrative flag. These are non-adjudicated same-image text flags, not pathology labels.", style="Caption")
    add_table(
        sup,
        ["Patient", "Cancer", "Eligible slides", "Flagged slides", "Primary-analysis use"],
        [(r.get("patient"), str(r.get("project_id", "")).replace("TCGA-", ""),
          r.get("n_slides"), r.get("narrative_no_residual_tumour_slides"),
          "Not used for exclusion or weighting")
         for r in pathology_qc_no_residual_patients],
        widths=[3.0, 2.0, 2.2, 2.2, 6.0], font_size=7.5, header_font_size=7.8,
        line_spacing=1.0, fixed_layout=True,
    )
    if no_residual_exclusion_summary:
        sup.add_paragraph("Panel C. Non-adjudicated exclusion sensitivity. All flagged patients were removed before fold construction and every screen-positive model in the affected cancers was refitted. The material-change flag is descriptive: loss of the original effect threshold or an absolute effect change of at least 0.05; it is not an inferential criterion.", style="Caption")
        add_table(
            sup,
            ["Outcome", "Models", "Median change", "5th–95th percentile", "Threshold retained", "Material-change flags", "Highlighted flags"],
            [(r.get("outcome_type"), r.get("models"), fnum(r.get("median_delta")),
              f"{fnum(r.get('q05_delta'))} to {fnum(r.get('q95_delta'))}",
              f"{r.get('threshold_retained')}/{r.get('models')}",
              r.get("material_change_flags"), r.get("highlighted_material_change_flags"))
             for r in no_residual_exclusion_summary],
            widths=[2.0, 1.5, 2.2, 3.0, 2.4, 2.5, 2.3],
            font_size=7.2, header_font_size=7.5, line_spacing=1.0,
            fixed_layout=True,
        )
        sup.add_paragraph(
            f"All {len(no_residual_exclusion_highlighted)} highlighted models retained the original threshold; their largest absolute effect change was {fnum(no_residual_highlighted_max_abs_delta)} Q². Complete endpoint-level results are in nonadjudicated_no_residual_exclusion_all.csv and its outcome-specific companions.",
            style="Caption",
        )
if molecular_slide_linkage:
    add_landscape_section(sup)
    sup.add_heading("Table S3c. Molecular–slide linkage resolution by source", 1)
    sup.add_paragraph("The unit is a unique TITAN embedding-cohort patient covered by each molecular source, not a cancer–endpoint test. Exact linkage denotes agreement of the 15-character TCGA sample barcode. It does not prove that the WSI and assay used the same tissue portion, analyte, aliquot, block or tumour region. NA indicates that the source supplied only a participant identifier.")
    add_table(
        sup,
        ["Source", "Identifier resolution", "Covered patients", "Exact sample match", "Participant-only/nonmatching", "Multiple molecular primary samples", "Residual label-noise interpretation"],
        [(r.get("source"), r.get("identifier_resolution"), r.get("covered_patients"),
          (f"{r.get('exact_slide_sample_patients')} ({fnum(r.get('exact_percent_all_covered'), 1)}%)" if r.get("exact_slide_sample_patients") else "NA"),
          r.get("participant_only_or_nonmatching_patients"),
          r.get("patients_with_multiple_molecular_primary_samples") or "NA",
          r.get("label_noise_note")) for r in molecular_slide_linkage],
        [3.2, 3.0, 2.0, 2.5, 2.8, 3.0, 8.0],
    )
if slide_heterogeneity and median_pool_summary:
    sup.add_heading("Table S3d. Pooling and within-patient embedding heterogeneity sensitivity", 1)
    sup.add_paragraph("Panel A summarizes only patients with more than one diagnostic slide. Cosine distances are numerical embedding diagnostics and do not identify tumour content, artefact or biological subclones. Leave-one-slide-out is the maximum cosine distance between the full mean centroid and a centroid recomputed after omitting one slide.", style="Caption")
    add_table(
        sup,
        ["Representation", "Patients", "Multi-slide", "Median pairwise cosine distance", "95th percentile", "Median max leave-one-out centroid change", "95th percentile"],
        [(display_representation(r.get("foundation_model")), r.get("patients"), r.get("multi_slide_patients"),
          fnum(r.get("median_pairwise_cosine_distance"), 4), fnum(r.get("q95_pairwise_cosine_distance"), 4),
          fnum(r.get("median_maximum_loo_centroid_distance"), 4), fnum(r.get("q95_maximum_loo_centroid_distance"), 4))
         for r in slide_heterogeneity],
        [2.7, 1.7, 1.8, 3.2, 2.2, 4.0, 2.2],
    )
    sup.add_paragraph("Panel B refits every TITAN candidate after coordinate-wise median pooling; the first-slide analysis is retained as a deliberately more disruptive deterministic alternative.", style="Caption")
    add_table(
        sup,
        ["Outcome", "Models", "Median median-minus-mean change", "5th–95th percentile", "Mean/median rank correlation", "Threshold retained", "First-slide rank correlation"],
        [(r.get("outcome_type"), r.get("models"), fnum(r.get("median_delta")),
          f"{fnum(r.get('q05_delta'))} to {fnum(r.get('q95_delta'))}",
          fnum(r.get("correlation_with_mean")), r.get("retained_original_effect_threshold"),
          ("0.964" if r.get("outcome_type") == "continuous" else "0.921"))
         for r in median_pool_summary],
        [2.0, 1.5, 3.5, 3.2, 3.3, 2.2, 3.0],
    )
    sup.add_paragraph("Panel C removes TCGA-DX-AB2L before fold construction and refits all SARC candidates. Endpoint-level estimates, including the three threshold changes, are provided in the machine-readable companions.", style="Caption")
    add_table(
        sup,
        ["Outcome", "SARC models", "Patient labelled", "Median change", "Range", "Threshold retained"],
        [("Continuous", len(sarc_exclusion_c), sum(ival(r.get("original_n"))-ival(r.get("exclusion_n")) for r in sarc_exclusion_c),
          fnum(statistics.median(float(r.get("delta_exclusion_minus_original")) for r in sarc_exclusion_c)),
          f"{fnum(min(float(r.get('delta_exclusion_minus_original')) for r in sarc_exclusion_c))} to {fnum(max(float(r.get('delta_exclusion_minus_original')) for r in sarc_exclusion_c))}",
          f"{sum(float(r.get('exclusion_q2')) >= 0.20 for r in sarc_exclusion_c)}/{len(sarc_exclusion_c)}"),
         ("Binary", len(sarc_exclusion_b), sum(ival(r.get("original_n"))-ival(r.get("exclusion_n")) for r in sarc_exclusion_b),
          fnum(statistics.median(float(r.get("delta_exclusion_minus_original")) for r in sarc_exclusion_b)),
          f"{fnum(min(float(r.get('delta_exclusion_minus_original')) for r in sarc_exclusion_b))} to {fnum(max(float(r.get('delta_exclusion_minus_original')) for r in sarc_exclusion_b))}",
          f"{sum(float(r.get('exclusion_balanced_accuracy')) >= 0.60 for r in sarc_exclusion_b)}/{len(sarc_exclusion_b)}")],
        [2.1, 2.0, 2.4, 2.4, 3.0, 2.5],
    )
    changed_sarc = [
        ("Continuous", r.get("endpoint"), "Q²", r.get("original_q2"), r.get("exclusion_q2"))
        for r in sarc_exclusion_c
        if float(r.get("original_q2")) >= 0.20 and float(r.get("exclusion_q2")) < 0.20
    ] + [
        ("Binary", r.get("endpoint"), "Balanced accuracy", r.get("original_balanced_accuracy"), r.get("exclusion_balanced_accuracy"))
        for r in sarc_exclusion_b
        if float(r.get("original_balanced_accuracy")) >= 0.60 and float(r.get("exclusion_balanced_accuracy")) < 0.60
    ]
    sup.add_paragraph("Panel D. Models falling below the original effect threshold after exclusion.", style="Caption")
    add_table(sup, ["Outcome", "Endpoint", "Metric", "Original", "After exclusion"],
              [(a, b, c, fnum(d), fnum(e)) for a, b, c, d, e in changed_sarc],
              [2.2, 4.5, 3.0, 2.2, 2.5], trailing_paragraph=False,
              font_size=7.0, header_font_size=7.2, line_spacing=0.9,
              fixed_layout=True)
if molecular_slide_linkage:
    add_portrait_section(sup)
sup.add_heading("Table S4. Mutation molecular coverage by cancer", 1)
sup.add_paragraph(f"Across {len(mutation_eligibility):,} documented cancer–gene pairs, {n_mutation_eligible:,} were eligible, {sum(r.get('eligibility') == 'insufficient_positive' for r in mutation_eligibility):,} had fewer than 20 positive patients and {sum(r.get('eligibility') == 'insufficient_negative' for r in mutation_eligibility):,} had fewer than 20 negative patients. These ineligible pairs were not entered into model fitting or multiplicity correction.")
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
    sup.add_paragraph("The initial nested-CV screening estimate and the five-repeat mean are labelled separately. Every interval in this table is a 95% selection-conditioned patient-resampling interval for repeated out-of-fold predictions. It resamples patients from five fixed held-out prediction sets and represents patient sampling variation conditional on those fitted partitions. It does not repeat screening, fold generation, tuning or model fitting, does not correct winner's-curse selection, and is not a confidence interval for external generalisation. The repeat median, interquartile range and crossing proportion describe the five fitted partitions directly and are not resampling intervals.")
    performance_rows = []
    deployment_rows = []
    for r in highlighted:
        if r.get("outcome_type") == "binary":
            primary = (f'Initial primary-screen BA {fnum(r.get("primary_screen_balanced_accuracy"))}; '
                       f'five-repeat mean BA {fnum(r.get("balanced_accuracy"))} '
                       f'(SC interval {fnum(r.get("balanced_accuracy_ci_low"))}-{fnum(r.get("balanced_accuracy_ci_high"))}); '
                       f'repeat median {fnum(r.get("repeat_metric_median"))} '
                       f'[IQR {fnum(r.get("repeat_metric_q1"))}-{fnum(r.get("repeat_metric_q3"))}]; '
                       f'crossing proportion {fnum(r.get("repeat_crossing_proportion"), 2)} '
                       f'({ival(r.get("repeat_crossing_count"))}/{ival(r.get("repeat_partitions"))})')
            class_metrics = (f'Five-repeat mean Se {fnum(r.get("sensitivity"))} '
                             f'({fnum(r.get("sensitivity_ci_low"))}–{fnum(r.get("sensitivity_ci_high"))}); '
                             f'Sp {fnum(r.get("specificity"))} '
                             f'({fnum(r.get("specificity_ci_low"))}–{fnum(r.get("specificity_ci_high"))})')
            other = (f'Five-repeat mean AUROC {fnum(r.get("auc"))} '
                     f'({fnum(r.get("auc_ci_low"))}–{fnum(r.get("auc_ci_high"))}); '
                     f'PR-AUC {fnum(r.get("pr_auc"))} '
                     f'({fnum(r.get("pr_auc_ci_low"))}–{fnum(r.get("pr_auc_ci_high"))}); '
                     f'PPV/NPV at TCGA prevalence {fnum(r.get("ppv_tcga_prevalence"))}/'
                     f'{fnum(r.get("npv_tcga_prevalence"))}')
        else:
            primary = (f'Initial primary-screen Q² {fnum(r.get("primary_screen_q2"))}; '
                       f'five-repeat mean Q² {fnum(r.get("q2"))} '
                       f'(SC interval {fnum(r.get("q2_ci_low"))}-{fnum(r.get("q2_ci_high"))}); '
                       f'repeat median {fnum(r.get("repeat_metric_median"))} '
                       f'[IQR {fnum(r.get("repeat_metric_q1"))}-{fnum(r.get("repeat_metric_q3"))}]; '
                       f'crossing proportion {fnum(r.get("repeat_crossing_proportion"), 2)} '
                       f'({ival(r.get("repeat_crossing_count"))}/{ival(r.get("repeat_partitions"))})')
            class_metrics = "Not applicable"
            other = (f'Five-repeat mean RMSE {fnum(r.get("rmse"))} '
                     f'({fnum(r.get("rmse_ci_low"))}–{fnum(r.get("rmse_ci_high"))}); '
                     f'ρ {fnum(r.get("spearman"))} '
                     f'({fnum(r.get("spearman_ci_low"))}–{fnum(r.get("spearman_ci_high"))})')
        performance_rows.append((
            r.get("outcome_type"), r.get("tumor_type") + "–" + r.get("endpoint"),
            r.get("n"), primary, class_metrics, other,
            f'{r.get("site_grouped_metric_name")} {fnum(r.get("site_grouped_metric"))}; '
            f'{r.get("site_robustness_status")}'
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
            f'TCGA tissue-source-site codes: {r.get("site_grouped_n_sites")}; '
            f'delta: {fnum(r.get("site_performance_delta"))}; '
            f'status: {r.get("site_robustness_status")}; '
            f'inner code-group separation: {r.get("site_grouped_inner_site_separation")}; '
            f'{r.get("redistribution_status")}'
        )
        deployment_rows.append((
            r.get("tumor_type") + "–" + r.get("endpoint"), model_metadata,
            classification_metadata, provenance_metadata
        ))
    add_table(sup, ["Type", "Cancer–endpoint", "n", "Initial primary screen; five-repeat mean, SC interval and partition distribution",
                    "Five-repeat sensitivity/specificity (95% SC interval)", "Other five-repeat metrics (95% SC interval)",
                    "Metric/status when grouped by TCGA tissue-source-site code"],
              performance_rows)
    sup.add_heading("Table S6b. Highlighted-model research-use and provenance metadata", 1)
    sup.add_paragraph(
        "Checksum prefixes are shown for readability; complete SHA-256 values are "
        "provided in highlighted_model_performance.csv and models/model_registry.csv."
    )
    add_table(sup, ["Cancer–endpoint", "Model and input", "Classification",
                    "Provenance and release status"], deployment_rows)
sup.add_heading("Table S6c. Prospectively locked subset for future independent evaluation", 1)
sup.add_paragraph("These three models were selected after the internal TCGA screen but before inspection of any external features, outcomes or predictions. ‘Internal TCGA evidence’ reports the five-repeat mean nested-CV estimate on each model’s full outcome-labelled TITAN cohort, followed by the separately calculated full-cohort sensitivity estimate grouped by TCGA tissue-source-site code; it is neither the initial primary-screen estimate nor a fitted-full-data apparent-performance value. The SHA-256 identifies the full-data artifact intended for future application. The external analysis has not been performed. No refitting, recalibration, class-prior change, threshold adjustment or outcome optimisation is permitted. Every target must be reported, including failure or non-evaluability.")
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
add_landscape_section(sup)
sup.add_heading("Table S6d. Representation-specific fitted-model inventory", 1)
sup.add_paragraph(f"Panel A. The controlled PathoFMPred registry contains {registry_object_total} fitted objects. TITAN models belong to the permutation/FDR-qualified TITAN atlas candidate layer. Giga-SSL and Prov-GigaPath objects are genuinely representation-specific coefficient fits, but both use the identical shared set of TITAN-qualified targets that remained eligible in the matched common cohort. Their identical 198-continuous/99-binary counts are therefore a target-universe design choice, not representation-specific crossing counts. Selecting foundation_model changes both schema and fitted coefficients.", style="Caption")
add_table(
    sup,
    ["Representation", "Outcome", "Family", "Fitted objects", "Evidential role"],
    [(r.get("foundation_model"), r.get("outcome_type"), r.get("family"),
      r.get("fitted_models"), r.get("evidential_role")) for r in model_inventory],
    [2.5, 1.8, 3.8, 2.0, 5.0],
)
sup.add_paragraph("Panel B. Reconciliation of the controlled object inventory with the matched three-representation atlas. A stored object may have tested below the threshold for that representation, and a representation-specific crossing may lack a stored object. Consequently, the registry is a partial—not complete—operationalization of the matched atlas. TITAN object counts derive from the larger TITAN-only permutation/FDR layer, so some are not eligible or do not cross in the common cohort.", style="Caption")
add_table(
    sup,
    ["Representation", "Outcome", "Matched crossings", "Controlled objects", "Objects crossing / below threshold", "Crossings with / without object", "Coverage"],
    [[display_representation(r.get("foundation_model")), r.get("outcome_type"),
      r.get("matched_effect_threshold_crossings"), r.get("controlled_objects"),
      f"{r.get('controlled_objects_crossing_for_representation')} / {r.get('controlled_objects_below_threshold_for_representation')}",
      f"{r.get('representation_crossings_with_controlled_object')} / {r.get('representation_crossings_without_controlled_object')}",
      f"{fnum(r.get('crossing_object_coverage_percent'), 1)}%"]
     for r in model_inventory_reconciliation],
    [2.4, 1.6, 2.0, 2.0, 3.4, 3.4, 1.8], font_size=7.0,
)
sup.add_paragraph("compare_pathofm_models() reports controlled-object availability, the object's target-selection basis and its representation-specific matched-threshold status in separate fields. It does not derive consensus from the number of stored objects and cannot list an atlas crossing for which no object exists; such tasks remain visible in the complete matched-atlas tables and fitted_model_inventory_reconciliation.csv.")
sup.add_heading("Table S6e. Software access and licensing matrix", 1)
sup.add_paragraph("This matrix records the authors' current release policy and is not a legal determination. Upstream terms remain authoritative and must be checked at the version used. The MIT licence on contributor-authored PathoFMPred source code does not relicense fitted objects, upstream representations or source datasets. The public package contains a minimal Giga-SSL fixture and checksum-verified, user-invoked downloads of the Giga-SSL and Prov-GigaPath fitted collections under separately stated asset terms and upstream attribution. The TITAN fitted collection remains available only in the private collaboration repository pending written redistribution permission.")
add_table(
    sup,
    ["Layer", "Licence or upstream terms", "Current access", "Reviewer access", "Reader access at publication", "Redistribution position"],
    [(r.get("layer"), r.get("current_licence_or_terms"), r.get("current_access"),
      r.get("reviewer_access"), r.get("reader_access_at_publication"),
      r.get("redistribution_position")) for r in software_access],
    [3.0, 4.2, 3.2, 4.2, 4.2, 4.2],
)
add_portrait_section(sup)
sup.add_heading("Table S7. Top continuous results from the initial nested-CV screen", 1)
sup.add_paragraph("The PDF shows the 15 highest primary-screen Q² values. continuous_screen.csv and continuous_repeated_nested_cv.csv contain all eligible and repeated-validation records.")
add_table(sup, ["Cancer", "Endpoint", "Family", "n", "Primary screen Q²", "q", "Category"],
          [(r["tumor_type"], r["endpoint"], r["family"], r["n"], fnum(r["q2"]), fnum(r["q_value"]), category(r["tier"])) for r in top_c[:15]])
sup.add_heading("Table S8. Top binary results from the initial nested-CV screen", 1)
sup.add_paragraph("The PDF shows the 15 highest primary-screen balanced-accuracy values. binary_screen.csv and binary_repeated_nested_cv.csv contain all eligible and repeated-validation records.")
add_table(sup, ["Cancer", "Endpoint", "Family", "n", "Positive", "Primary screen BA", "Five-repeat PR-AUC", "q", "Sample-size maturity/default"],
          [(r["tumor_type"], r["endpoint"], r["family"], r["n"], r["positive"], fnum(r["balanced_accuracy"]),
            fnum(binary_reliability_by_key.get((r["family"], r["tumor_type"], r["endpoint"]), {}).get("repeated_pr_auc_mean")),
            fnum(r["q_value"]),
            ("larger sample-size maturity; included" if binary_reliability_by_key.get((r["family"], r["tumor_type"], r["endpoint"]), {}).get("default_inference") == "TRUE" else "smaller sample-size maturity; excluded"))
           for r in top_b[:15]])
sup.add_heading("Table S9. Published exact cancer–gene results compared with the current screen", 1)
sup.add_paragraph("Prior studies predominantly reported AUROC, whereas the current documented screening metric is balanced accuracy. These values are displayed side by side for context but are not directly subtractable and do not constitute a head-to-head model comparison.")
sup.add_paragraph("The PDF retains 12 representative exact cancer-gene comparisons. prior_mutation_accuracy_comparison.csv contains the complete crosswalk.")
add_table(sup, ["Study", "Cancer", "Gene", "Prior result", "Current primary-screen BA", "Current q", "Current status"],
          [(r["study"], r["cancer"], r["gene"], r["prior_metric"], fnum(r["current_balanced_accuracy"]), fnum(r["current_q"]), r["current_status"].replace("_", " ")) for r in lit_accuracy[:12]])
sup.add_heading("Table S10a. Expanded literature audit for every screen-positive mutation predictor", 1)
sup.add_paragraph("The audit maps pooled colorectal cohorts to COAD and READ where appropriate and distinguishes prior statistical support, prior evaluation without support, and a result not identified in the reviewed predictive-model literature. The last category is not a claim of biological novelty or an exhaustive proof of bibliographic novelty.")
mutation_evidence_counts = Counter(r["evidence_class"] for r in mutation_literature_audit)
sup.add_paragraph("The PDF reports evidence-class counts. supported_mutation_literature_audit.csv retains every cancer-gene mapping, source, metric and decision.")
add_table(sup, ["Evidence class", "Cancer-gene pairs", "Interpretation"],
          [(evidence_class, count,
            "Targeted narrative cross-check; not a systematic-review novelty claim")
           for evidence_class, count in sorted(mutation_evidence_counts.items())])
sup.add_heading("Table S10b. Screen-positive models below the original documented screening threshold under validation grouped by TCGA tissue-source-site code", 1)
sup.add_paragraph("The PDF shows the 15 largest attenuations. site_grouped_models_below_effect_threshold.csv contains every threshold loss.")
add_table(sup, ["Type", "Family", "Cancer", "Endpoint", "n", "TCGA tissue-source-site codes", "Primary screen metric", "Metric grouped by TCGA tissue-source-site code", "Delta"],
          [(r.get("outcome_type"), r.get("family"), r.get("tumor_type"), r.get("endpoint"),
            r.get("n"), r.get("n_sites"), fnum(r.get("original_metric")),
            fnum(r.get("site_grouped_metric")), fnum(r.get("delta")))
           for r in sorted(site_threshold_failures, key=lambda x: float(x.get("delta") or 0))[:15]])
sup.add_heading("Table S10c. Outer-fold composition grouped by TCGA tissue-source-site code for the two colorectal APC examples", 1)
sup.add_paragraph(f"The table shows every outer fold for the two near-chance APC examples. The complete {len(site_fold_details):,}-row file reports test and training patients, TCGA tissue-source-site codes, positive and negative cases, code identifiers, seeds and inner-code-separation diagnostics for every screen-positive model. Inner component selection used the same grouping by TCGA tissue-source-site code and had no code overlap.")
site_predictability_display = sorted(
    site_predictability,
    key=lambda x: float(x.get("normalized_macro_balanced_accuracy") or "-inf"),
    reverse=True,
)[:12]
sup.add_paragraph("The PDF shows the 12 highest chance-normalized results. tissue_source_site_predictability_summary.csv contains all eligible and ineligible cancers.")
add_table(
    sup,
    ["Model", "Fold", "Test patients", "Test tissue-source-site codes", "Test positive/negative", "Training patients", "Training tissue-source-site codes", "Training positive/negative"],
    [(
        f'{r.get("tumor_type")}–{r.get("endpoint")}', r.get("outer_fold"),
        r.get("test_patients"), r.get("test_sites"),
        f'{r.get("test_positive")}/{r.get("test_negative")}',
        r.get("training_patients"), r.get("training_sites"),
        f'{r.get("training_positive")}/{r.get("training_negative")}'
    ) for r in site_fold_details
      if r.get("outcome_type") == "binary"
      and (r.get("tumor_type"), r.get("endpoint")) in {("READ", "APC"), ("COAD", "APC")}]
)
sup.add_heading("Table S10d. Within-cancer prediction of TCGA tissue-source-site code from TITAN representations", 1)
sup.add_paragraph("TCGA tissue-source-site codes represented by fewer than 10 patients were excluded only from this dedicated code-association analysis. Macro balanced accuracy is the mean recall across codes; its chance reference is 1/k for k analysed codes. Good code prediction demonstrates that the representation carries information about TCGA tissue-source-site code, but it does not establish endpoint confounding, and the code is not an institution, scanner, laboratory or staining-batch identifier.")
add_table(
    sup,
    ["Cancer", "Eligible", "Analysed patients", "Analysed tissue-source-site codes", "Macro BA, mean (SD)", "Chance 1/k", "Chance-normalised BA", "Reason if ineligible"],
    [(
        r.get("tumor_type"), r.get("eligible"), r.get("analysed_patients"),
        r.get("analysed_sites"),
        f'{fnum(r.get("macro_balanced_accuracy_mean"))} ({fnum(r.get("macro_balanced_accuracy_sd"))})',
        fnum(r.get("chance_macro_balanced_accuracy")),
        fnum(r.get("normalized_macro_balanced_accuracy")), r.get("error")
    ) for r in site_predictability_display]
)
if site_partition_summary:
    sup.add_heading("Table S10d2. Matched-partition, paired-uncertainty and code-only outcome controls", 1)
    sup.add_paragraph(f"Matched random outer partitions reproduce every grouped fold's test-set size and, for binary endpoints, its positive and negative counts. Paired intervals use 1,000 patient-resampling replicates of the grouped-minus-matched-random performance difference. Code-only performance uses training-fold code means or prevalences; it measures outcome information associated with code, not technical confounding. The complete {titan_candidate_total}-model table reports code heterogeneity, component counts and matching diagnostics.")
    add_table(sup, ["Outcome", "Models", "Median grouped−matched", "IQR", "Interval <0 / includes 0", "Median code-only metric", "Median code heterogeneity"],
              [[r["outcome_type"], r["models"], fnum(r["median_grouped_minus_matched"],3),
                f"{fnum(r['q1'],3)} to {fnum(r['q3'],3)}", f"{r['intervals_below_zero']}/{r['intervals_include_zero']}",
                fnum(r["median_code_only_metric"],3), fnum(r["median_code_heterogeneity"],3)] for r in site_partition_summary],
              [2.2,1.5,3.2,3.0,3.3,3.0,3.2])
    add_table(sup, ["Model", "Grouped BA", "Matched-random BA", "Δ (95% paired interval)", "Code-only AUROC", "Code prevalence range"],
              [[f"{r['tumor_type']}–{r['endpoint']}", fnum(r["grouped_metric"],3), fnum(r["matched_random_metric"],3),
                f"{fnum(r['grouped_minus_matched'],3)} ({fnum(r['paired_ci_low'],3)} to {fnum(r['paired_ci_high'],3)})",
                fnum(r["code_only_metric"],3), f"{fnum(r['minimum_prevalence_minimum5'],3)}–{fnum(r['maximum_prevalence_minimum5'],3)} (codes n≥5)"]
               for r in site_partition_controls if r["outcome_type"]=="binary" and r["tumor_type"] in {"COAD","READ"} and r["endpoint"]=="APC"],
              [3.0,2.2,3.0,4.5,3.0,3.0])
sup.add_heading("Table S10e. Metadata-stratified representative PLS–ridge benchmark", 1)
sup.add_paragraph("All 2,073 eligible tests entered the sampling frame. A fixed salted SHA-256 rank selected one endpoint per non-empty outcome-family × empirical sample-size-tercile cell; binary endpoints were additionally stratified by empirical minority-class-fraction tercile. Selection did not use PLS performance and yielded 12 continuous and 35 binary targets. Both algorithms used identical patients, outer folds and inner folds. Continuous hyperparameters maximised the same pooled inner out-of-fold Q²; binary operating thresholds maximised the same inner out-of-fold balanced accuracy. For repeat r, d_r=M_r(ridge)−M_r(PLS), with Δ=(1/5)Σ_r d_r. Each of 2,000 paired patient-resampling replicates retained both methods and all five predictions. The interval does not repeat target sampling, generate partitions or refit models, and it does not represent external transportability. This is representative rather than atlas-wide. Positive differences favour ridge.")
sup.add_paragraph("Panel A. Sampling-stratum summary for the primary metric.", style="Caption")
add_table(
    sup,
    ["Type", "Stratifier", "Stratum", "Models", "Median Δ", "IQR", "PLS/ridge/uncertain"],
    [(
        benchmark_type_label(r.get("outcome_type")), r.get("stratifier"),
        benchmark_family_label(r.get("stratum")), r.get("models"),
        fnum(r.get("median_delta_ridge_minus_pls")),
        f'{fnum(r.get("q1_delta"))} to {fnum(r.get("q3_delta"))}',
        f'{r.get("pls_better")}/{r.get("ridge_better")}/{r.get("difference_uncertain")}'
    ) for r in ridge_stratified]
)
sup.add_paragraph("Target-level primary and secondary metrics, repeat-level paired differences and patient-resampling intervals reside in pls_vs_ridge_representative_models.csv, pls_vs_ridge_representative_repeated_nested_cv.csv and pls_vs_ridge_representative_paired_repeat_metrics.csv.")
sup.add_heading("Table S10f. Permutation precision and atlas-wide multiplicity sensitivity", 1)
sup.add_paragraph("Panel A. Raw p-value assignment and multiplicity-denominator audit. ‘Below checkpoint’ means the model did not enter permutation testing and received raw p=1. ‘Early stopped’ means permutation testing began but reached 49 exceedances, making raw p<0.05 impossible, and was censored to raw p=1. These statuses are distinct in the registry. Every eligible row in both categories remains in every applicable BH denominator.", style="Caption")
add_table(
    sup,
    ["Outcome", "Eligible", "Below checkpoint p=1", "Early-stopped p=1", "Completed 999", "Outcome-wide denominator", "Atlas-wide denominator"],
    [[r["outcome_type"], r["eligible_tests"],
      r["below_checkpoint_assigned_p1"], r["early_stopped_assigned_p1"],
      r["completed_tests_with_999_permutations"],
      r["outcome_wide_bh_denominator"], r["atlas_wide_bh_denominator"]]
     for r in multiplicity_p_assignment],
    [2.0, 1.5, 2.8, 2.7, 2.1, 3.0, 2.7],
)
sup.add_paragraph("The row-level multiplicity_denominator_audit.csv also records local and across-cancer/family denominator sizes and recomputed-versus-saved q-values. Local denominators ranged from 1–50 continuous and 1–48 binary tests; across-cancer/family denominators ranged from 30–1,434 and 3–238, respectively. All recomputed q-values matched the saved analysis fields to numerical tolerance.")
sup.add_paragraph("Panel B. Candidate retention under increasingly broad Benjamini–Hochberg sensitivities. The primary candidate definition documented in the initial repository snapshot is within cancer and endpoint family. The atlas-wide column applies one correction to every eligible continuous and binary cancer–endpoint test; it is a sensitivity analysis rather than a replacement of that local question.", style="Caption")
add_table(
    sup,
    ["Outcome", "Eligible", "Screening-threshold eligible", "Local candidates", "Across-cancer family", "Outcome-wide", "Atlas-wide"],
    [(
        r.get("outcome_type"), r.get("eligible_tests"), r.get("effect_eligible"),
        r.get("within_cancer_family_candidates"), r.get("across_cancer_family_pass"),
        r.get("outcome_wide_pass"), r.get("atlas_wide_pass")
    ) for r in multiplicity_summary]
)
sup.add_paragraph("Panel C. Targeted high-resolution refinement. All models reuse the saved first 999 permutations and continue the same deterministic permutation-index sequence to 9,999. Every permutation repeats training-fold centering, inner component selection, outer refitting and held-out prediction. Refined p-values and exact Monte Carlo intervals are precision sensitivities and were not substituted into the primary FDR screen.", style="Caption")
add_table(
    sup,
    ["Type", "Cancer", "Endpoint", "b/999", "p (999)", "b/9,999", "p (9,999)", "95% MC interval"],
    [(
        benchmark_type_label(r.get("outcome_type")), r.get("tumor_type"),
        r.get("endpoint"), r.get("primary_exceedances_999"),
        fnum(r.get("primary_p_999"), 4), r.get("refined_exceedances_9999"),
        fnum(r.get("refined_p_9999"), 4),
        f'{fnum(r.get("refined_mc_lower_95"), 6)} to {fnum(r.get("refined_mc_upper_95"), 6)}'
    ) for r in targeted_permutation]
)
# The table helper appends an empty paragraph. When this table exactly fills the
# portrait page, that paragraph can spill to a blank page before the landscape
# section break in LibreOffice. Remove only that known trailing spacer.
if sup.paragraphs and not sup.paragraphs[-1].text.strip():
    spacer = sup.paragraphs[-1]._element
    spacer.getparent().remove(spacer)
add_landscape_section(sup)
sup.add_heading("Table S10g. Binary class-size sensitivity and development reliability", 1)
sup.add_paragraph("Panel A. Eligibility and screen-positive retention. The 20-per-class row is the inclusive atlas screen documented in the initial repository snapshot; the 50-per-class row defines standard internal evidence and default inference eligibility.", style="Caption")
add_table(
    sup,
    ["Minimum/class", "Eligible binary pairs", "Screen-positive models", "Eligible retention", "Candidate retention", "Interpretation"],
    [(
        r.get("minimum_per_class"), r.get("eligible_binary_targets"),
        r.get("screen_positive_binary_models"),
        f'{fnum(r.get("eligible_target_retention_percent"), 1)}%',
        f'{fnum(r.get("screen_positive_retention_percent"), 1)}%',
        r.get("interpretation"),
    ) for r in binary_class_sensitivity],
    [2.2, 3.0, 3.2, 2.7, 2.7, 9.0],
)
sup.add_paragraph("The 17 model-level class counts, PR-AUC, predictive values, inner-fold composition, component distributions, score stability and call agreement reside in binary_limited_evidence_models.csv, binary_outer_fold_class_counts.csv, binary_selected_components_by_fold.csv and binary_prediction_stability.csv.")
sup.add_heading("Table S10h. Continuous sample-size and development reliability", 1)
sup.add_paragraph("Panel A. Distribution by outcome-labelled sample-size band. Q² and stability are five-repeat summaries; stability is the mean pairwise Spearman correlation between patient-level repeated out-of-fold predictions.", style="Caption")
add_table(
    sup,
    ["Sample-size band", "Models", "n median (range)", "Median Q²", "Median Q² SD", "Median stability", "Median components", "Ceiling fits"],
    [(r.get("sample_size_band"), r.get("models"), f'{fnum(r.get("n_median"), 0)} ({r.get("n_min")}–{r.get("n_max")})',
      fnum(r.get("q2_median")), fnum(r.get("q2_repeat_sd_median")), fnum(r.get("prediction_repeat_spearman_median")),
      fnum(r.get("selected_components_median"), 1), f'{r.get("outer_fits_at_ceiling")}/{r.get("outer_fits")}')
     for r in continuous_reliability_bands],
    [2.4, 1.3, 2.6, 1.8, 2.0, 2.1, 2.3, 2.0],
)
sup.add_paragraph("Panel B. Six smallest candidates in the smaller-sample stratum. continuous_limited_evidence_models.csv contains all 13 models. These models remain in the complete atlas but are excluded from default inference; the label is not an evidence grade.", style="Caption")
add_table(
    sup,
    ["Cancer", "Endpoint", "n", "Mean Q²", "Q² SD", "Repeat stability", "Components median (range)", "Ceiling fits"],
    [(r.get("tumor_type"), r.get("endpoint"), r.get("n"), fnum(r.get("repeated_q2_mean")), fnum(r.get("repeated_q2_sd")),
      fnum(r.get("prediction_repeat_spearman_mean")), f'{fnum(r.get("selected_components_median"), 1)} ({r.get("selected_components_min")}–{r.get("selected_components_max")})',
      f'{r.get("outer_fits_at_ceiling")}/{r.get("outer_fits")}') for r in sorted(continuous_limited_reliability, key=lambda x: ival(x.get("n")))[:6]],
    [1.8, 4.8, 1.0, 1.6, 1.4, 2.0, 3.1, 1.8],
)
add_portrait_section(sup)
add_figure(sup, "FigureS3_binary_class_reliability.png", "Figure S1. Binary class-size reliability. Panel A shows fixed-test-fold learning curves for all 17 exploratory/limited-evidence models at 50%, 75% and 100% of each outer-training set. Panel B shows selected components across the 25 repeated outer fits per model. Panel C compares repeat score correlation and class-call agreement; high agreement under imbalance should not be interpreted without the continuous-score stability and class-specific metrics.")
if binary_decision_all:
    sup.add_heading("Table S10i. Complete binary operating-rule sensitivity", 1)
    sup.add_paragraph(
        "Panel A. Every eligible binary pair was rerun on identical outer partitions with the documented empirical-training-prior LDA rule, equal LDA priors and an operating threshold selected from pooled inner held-out scores to maximise balanced accuracy. Emp./equal/opt. are effect-threshold crossings at balanced accuracy ≥0.60. Retained/lost/gained compare the optimized rule with the recomputed empirical-prior baseline. Matched-atlas crossings remain descriptive; newly gained TITAN crossings are not permutation/FDR-qualified under the alternative rule.",
        style="Caption",
    )
    add_table(
        sup,
        ["Analysis layer", "Representation", "Eligible", "Emp./equal/opt. crossings", "Optimized retained/lost/gained", "Median ΔBA equal/optimized"],
        [(
            r.get("layer"), display_representation(r.get("foundation_model")),
            r.get("tasks"),
            f"{r.get('baseline_empirical_prior_crossings')}/{r.get('equal_prior_crossings')}/{r.get('optimized_crossings')}",
            f"{r.get('baseline_retained_optimized')}/{r.get('baseline_lost_optimized')}/{r.get('optimized_gained')}",
            f"{fnum(r.get('median_equal_delta_ba'))}/{fnum(r.get('median_optimized_delta_ba'))}",
        ) for r in binary_decision_all],
        [4.5, 3.0, 1.5, 4.0, 4.3, 4.0],
    )
    sup.add_paragraph(
        f"In the TITAN screen universe, {titan_optimized_gains_limited}/{len(titan_optimized_gains)} optimized-rule gains had fewer than 50 patients in the minority class. Overall, limited-class endpoints comprised {titan_optimized_crossing_limited}/{ival(titan_decision_all.get('optimized_crossings'))} optimized-rule crossings and {titan_empirical_crossing_limited}/{ival(titan_decision_all.get('baseline_empirical_prior_crossings'))} empirical-prior crossings. These alternative crossings remain exploratory and do not alter default-inference eligibility or permutation/FDR qualification.",
        style="Caption",
    )
    sup.add_paragraph(
        "Panel B. Twelve largest absolute operating-rule changes among pairs whose crossing membership changed. The complete row-level results, including sensitivity, specificity, AUROC, PR-AUC, selected components and all changes, are binary_decision_rule_sensitivity.csv; binary_decision_rule_fold_thresholds.csv contains every outer-fold class count, selected component and training-only threshold.",
        style="Caption",
    )
    add_table(
        sup,
        ["Layer/model", "Cancer–endpoint", "+/−", "BA empirical/equal/optimized", "Crossing empirical/equal/optimized"],
        [(
            f"{r.get('layer')}; {display_representation(r.get('foundation_model'))}",
            f"{r.get('tumor_type')}–{r.get('endpoint')}",
            f"{r.get('positive')}/{r.get('negative')}",
            f"{fnum(r.get('recomputed_primary_balanced_accuracy'))}/{fnum(r.get('equal_prior_balanced_accuracy'))}/{fnum(r.get('optimized_balanced_accuracy'))}",
            f"{r.get('recomputed_primary_crossing')}/{r.get('equal_prior_crossing')}/{r.get('optimized_crossing')}",
        ) for r in binary_decision_union_changes[:12]],
        [5.2, 5.6, 1.7, 4.7, 5.2],
    )
sup.add_heading("Table S10j. AUROC-centred matched binary benchmark and operating-rule sensitivity", 1)
sup.add_paragraph(
    "All 426 matched binary cancer–endpoint pairs use one coherent estimand. Pooled inner out-of-fold AUROC selects the component count, outer out-of-fold AUROC is the primary paired statistic, and AUROC≥0.60 defines the descriptive crossing. A balanced-accuracy-maximising threshold learned from the same inner training scores supplies operating-point metrics. Empirical-prior and equal-prior calls are secondary sensitivities on the identical selected component and outer score. No matched crossing is representation-specific permutation/FDR-qualified.",
    style="Caption",
)
add_table(
    sup,
    ["Representation", "Tasks", "Primary AUROC crossings", "Median AUROC", "Median PR-AUC", "Median prevalence", "Training-threshold BA crossings", "Ceiling fits"],
    [[display_representation(m),
      r["tasks"], r["auroc_tuned_auroc_crossings"],
      fnum(binary_operating_value(m, 'training-only optimized threshold', 'median_auroc'), 3),
      fnum(binary_operating_value(m, 'training-only optimized threshold', 'median_pr_auc'), 3),
      fnum(binary_operating_value(m, 'training-only optimized threshold', 'median_prevalence'), 3),
      binary_operating_value(m, 'training-only optimized threshold', 'ba_crossings_for_sensitivity'),
      f"{r['component_ceiling_outer_fits']}/2,130"]
     for m in ("TITAN", "GigaSSL", "ProvGigaPath")
     for r in [foundation_binary_auroc_by_model[m]]],
    [2.4, 1.2, 2.7, 2.0, 2.0, 2.1, 3.0, 2.0],
)
sup.add_paragraph(
    "Panel B. Operating-point comparison on identical AUROC-selected outer scores. Deltas are relative to empirical-training-prior calls. AUROC and PR-AUC are unchanged by these call rules.",
    style="Caption",
)
add_table(
    sup,
    ["Representation", "Call rule", "Median BA", "BA crossings", "Median ΔBA", "Median Δsensitivity", "Median Δspecificity", "Median ΔPPV", "Median ΔNPV"],
    [[display_representation(r["foundation_model"]), r["rule"],
      fnum(r["median_balanced_accuracy"], 3), r["ba_crossings_for_sensitivity"],
      fnum(r["median_ba_delta_vs_empirical"], 3),
      fnum(r["median_sensitivity_delta_vs_empirical"], 3),
      fnum(r["median_specificity_delta_vs_empirical"], 3),
      fnum(r["median_ppv_delta_vs_empirical"], 3),
      fnum(r["median_npv_delta_vs_empirical"], 3)]
     for r in foundation_binary_operating_summary],
    [2.4, 3.5, 1.8, 1.9, 1.8, 2.4, 2.4, 2.0, 2.0],
)
sup.add_paragraph(
    "Complete target-, fold- and patient-level outputs are supplied in foundation_model_binary_auroc_tuned_sensitivity.csv, foundation_model_binary_auroc_tuned_folds.csv, foundation_model_binary_operating_rule_metrics.csv, foundation_model_binary_operating_rule_paired_summary.csv and foundation_model_binary_auroc_tuned_oof.rds.",
    style="Caption",
)
sup.add_heading("Table S11. Prior histology-based molecular and derived immune-feature prediction landscape", 1)
add_table(sup, ["Study", "Year", "Scope", "Endpoints", "Development cohort", "External validation", "Reported performance", "DOI"],
          [(r.get("study"), r.get("year"), r.get("scope"), r.get("endpoints"),
            r.get("development_cohort"), r.get("external_validation"),
            r.get("reported_performance"), r.get("doi")) for r in literature_landscape])
sup.add_heading("Table S12. TRIPOD+AI reporting map", 1)
sup.add_paragraph("Items are mapped to the revised manuscript and repository using the official TRIPOD+AI checklist (version 11 January 2024). Pending entries require author or institutional information and are not statistical-analysis omissions.")
add_table(sup, ["Item", "Topic", "Reported location", "Status"],
          [(r.get("item"), r.get("topic"), r.get("reported_location"), r.get("status"))
           for r in tripod_map])
add_landscape_section(sup)
sup.add_heading("Table S13. Endpoint provenance, derivation and assay equivalence", 1)
sup.add_paragraph("Panel A. High-level label-generation classes. 'Definitions' counts unique outcome type–family–endpoint combinations; tests are cancer-specific. The synchronized 2,073-row target-level dictionary is the complete-resolution companion and reports all requested fields for every target.", style="Caption")
add_table(
    sup,
    ["Measurement class", "Cancer–endpoint tests", "Unique definitions", "Same-H&E-modality tests"],
    endpoint_class_summary,
    [8.0, 4.0, 4.0, 4.5],
)
sup.add_paragraph("Panel B. Compact derivation-group view. Expected measurement error, biological interpretation, transformation, missingness and source reference remain target-specific in endpoint_dictionary.csv and endpoint_definition_dictionary.csv.", style="Caption")
add_table(
    sup,
    ["Definition group", "Measurement class", "Tests/definitions", "Source modality", "Direct/inferred", "Derivation and source scale", "Assay-equivalence caveat"],
    [(
        group, measurement_class, f"{tests}/{definitions}", modality,
        directness, f"{derivation}; scale: {scale}", caveat
    ) for group, measurement_class, tests, definitions, modality, directness,
          derivation, scale, caveat in definition_group_summary],
    [4.0, 4.2, 2.2, 5.0, 4.6, 8.2, 6.0],
)
sup.add_paragraph("Panel C. Published outcome sources and participant-level construction. The complete machine-readable companion is outcome_source_acquisition_map.csv.", style="Caption")
add_table(
    sup,
    ["Source", "Published file or sheet", "Label domains", "Identifier", "Processing, aggregation and missingness"],
    [[r["source"], r["local_source"], r["label_domains"], r["source_identifier"],
      r["input_processing"] + "; " + r["participant_aggregation"] + "; " +
      r["missing_or_negative_rule"] + "; " + r["analysis_transformation"]]
     for r in outcome_source_acquisition],
    [3.2, 4.3, 6.1, 3.8, 9.0], font_size=6.0, header_font_size=6.3,
    line_spacing=1.0, fixed_layout=True,
)
sup.add_heading("Table S14. Qualitative high/low prediction anchors and within-cancer TITAN neighbours", 1)
sup.add_paragraph("Panel A. Five representative modality classes. Prediction values retain their original analysed units. TIL Regional Fraction is a same-H&E-modality concordance example; the remaining rows are descriptive cross-modal contexts.", style="Caption")
add_table(
    sup,
    ["Cancer–endpoint", "Target class", "High patient: observed/predicted", "Low patient: observed/predicted", "Interpretation"],
    [(
        f'{r.get("tumor_type")}–{r.get("endpoint")}', r.get("context_class"),
        f'{r.get("high_anchor")}: {fnum(r.get("high_observed"), 4)}/{fnum(r.get("high_prediction"), 4)}',
        f'{r.get("low_anchor")}: {fnum(r.get("low_observed"), 4)}/{fnum(r.get("low_prediction"), 4)}',
        r.get("interpretation"),
    ) for r in morphology_context_summary],
    [5.0, 5.0, 5.2, 5.2, 10.5],
)
sup.add_paragraph("morphology_context_examples.csv contains the complete anchor and nearest-neighbour records, including patient and slide identifiers, original predictions, ranks, cosine similarities and generated-report terms. The large point-level figure was removed from the PDF because it provides qualitative context rather than inferential evidence.")
sup.add_paragraph(
    "Spatial interpretation and pathology-review status. We did not perform blinded pathologist review or spatial relevance localisation. The retained analysis artifacts contain global patient-level or slide-level vectors only; they do not contain patch or tile embeddings, attention maps, relevance maps or WSI pixels from which a spatial analysis could be reconstructed. We therefore retain the nearest-neighbour examples only as qualitative context and exclude them from evidence prioritisation. A valid follow-up should select a small set of direct or sequence-derived associations with strong effects, stable alternative-partition ranks and adequate grouped folds, regenerate tile-level features or relevance maps from the exact slides, and assess prespecified regions in a blinded independent pathology review. Until then, this study makes no claim about the tissue compartment or morphological feature that supports any association."
)
sup.add_heading("Table S15. Matched foundation-model cohort and effect-threshold comparison", 1)
sup.add_paragraph("All comparative performance statements concern the complete released representation pipelines and are conditional on the specified downstream PLS regression/PLS-LDA probe. Model version, pretraining exposure, encoder, released layer, dimensionality and resolution metadata are summarised in main-text Table 1. In particular, direct TCGA image overlap cannot be excluded for Giga-SSL development, whereas the reported TITAN and Prov-GigaPath pretraining corpora excluded TCGA. Downstream molecular labels were held out in all three pipelines, but only TITAN and Prov-GigaPath were evaluated under a reported TCGA-unseen representation-pretraining condition. Physical input resolution and upstream pixel processing were not harmonised.")
add_table(
    sup,
    ["Representation", "Slides available", "Patients available", "Patients matched", "Dimensions", "Continuous crossings", "Binary crossings"],
    [(
        m, foundation_cohort_by_model[m]["source_slides"],
        foundation_cohort_by_model[m]["patients"],
        foundation_common_n,
        foundation_cohort_by_model[m]["dimensions"],
        foundation_crossings(m, "continuous"),
        foundation_crossings(m, "binary"),
    ) for m in ("TITAN", "GigaSSL", "ProvGigaPath")],
    [3.8, 2.6, 2.8, 2.5, 2.2, 3.0, 2.8],
)
sup.add_paragraph("All comparisons used the same 8,241-patient intersection and identical outcome-labelled patient subsets, folds, seeds and tuning rules within each task. A crossing means Q²≥0.20 for continuous outcomes or AUROC≥0.60 for binary outcomes. No representation-specific permutation or FDR requirement was applied; these counts are not screen-positive discoveries or evidence of external validity.")
if foundation_component_audit:
    sup.add_heading("Table S15a. PLS selected-component ceiling audit", 2)
    sup.add_paragraph("The table covers the complete 1,933-task matched atlas under the fixed 1–10-component PLS/PLS–LDA probe. Target ceiling % is the proportion of cancer–endpoint tasks for which at least one of five outer fits selected component 10; outer-fit ceiling % uses all individual outer fits. The distinction separates occasional ceiling selection from systematic ceiling selection. No completed fit used a numerical fallback; fitting errors stopped the pipeline rather than being silently replaced.")
    add_table(
        sup,
        ["Representation", "Outcome", "Targets", "Median selected", "Targets with any ceiling", "Target ceiling %", "Outer fits at ceiling / total", "Outer-fit ceiling %"],
        [[r["foundation_model"], r["outcome_type"], r["targets"], fnum(r["selected_components_median"], 1),
          r["targets_with_any_outer_fit_at_ceiling"], fnum(r.get("target_ceiling_percent"), 1),
          f"{r.get('outer_fits_at_ceiling', 'NA')}/{r.get('outer_fits_total', 'NA')}",
          fnum(r.get("outer_fit_ceiling_percent"), 1)] for r in foundation_component_audit],
        [2.7, 1.8, 1.4, 1.9, 2.7, 2.0, 3.0, 2.0],
    )
if foundation_probe_summary:
    sup.add_heading("Table S15b. Representation-ranking sensitivity to ridge", 2)
    sup.add_paragraph("The 47-target subset was fixed by outcome metadata before either representation comparison. Binary ranking uses AUROC and continuous ranking uses Q². Ridge models used identical target-labelled patients and target-specific folds across representations. This is a representative downstream-probe sensitivity, not an atlas-wide ridge benchmark or external validation.")
    add_table(sup, ["Outcome", "Targets", "Same winner", "Same-winner %"],
              [[r["outcome_type"], r["targets"], r["winner_retained"], fnum(r["winner_retained_percent"], 1)] for r in foundation_probe_summary],
              [3.5, 2.5, 3.0, 3.0])
if foundation_binary_component20_summary:
    sup.add_heading("Table S15c. Expanded 1-20-component sensitivity for 366 binary pairs", 2)
    sup.add_paragraph(
        "We expanded the component range for every binary pair that crossed AUROC 0.60 in at least one representation or lay within 0.05 of that threshold. The analysis retained the primary outer folds, pooled inner AUROC objective, rSVD seed schedule and training-only operating-threshold rule. It changed only the maximum component count. Negative AUROC changes indicate lower held-out performance under the expanded grid. The primary leading representation was retained for 323/366 pairs (88.3%) and changed for 43."
    )
    sup.add_paragraph("Panel A. Target-level performance and component-ceiling summary.", style="Caption")
    add_table(
        sup,
        ["Representation", "Pairs", "Crossings 1-10/1-20", "Median AUROC change", "Maximum absolute change", "Pairs with any ceiling 1-10/1-20", "Outer fits at ceiling 1-10/1-20", "Failures/fallbacks"],
        [[display_representation(r["foundation_model"]), r["tasks"],
          f"{r['primary_crossings']}/{r['expanded_crossings']}",
          fnum(r["median_auroc_delta"], 3),
          fnum(r["maximum_absolute_auroc_delta"], 3),
          f"{r['primary_tasks_with_any_ceiling_fit']}/{r['expanded_tasks_with_any_ceiling_fit']}",
          f"{r['primary_outer_fits_at_ceiling']}/{r['expanded_outer_fits_at_ceiling']}",
          f"{r['numerical_failures']}/{r['fallbacks']}"]
         for r in sorted(foundation_binary_component20_summary, key=lambda x: ("TITAN", "GigaSSL", "ProvGigaPath").index(x["foundation_model"]))],
        [2.5, 1.2, 2.8, 2.4, 2.6, 3.4, 3.4, 2.2], font_size=6.7,
    )
    sup.add_paragraph("Panel B. Selected-component distributions across 1,830 outer fits per representation and grid. The final column lists the three most frequent selected components with their outer-fit percentages.", style="Caption")
    component_distribution_rows = []
    for model in ("TITAN", "GigaSSL", "ProvGigaPath"):
        for grid in ("1-10", "1-20"):
            z = foundation_binary_component_distribution_summary[(model, grid)]
            component_distribution_rows.append([
                display_representation(model), grid, "1,830",
                z["median"], f"{z['q1']} to {z['q3']}", z["top"],
            ])
    add_table(
        sup,
        ["Representation", "Grid", "Outer fits", "Median selected", "Interquartile range", "Three most frequent components"],
        component_distribution_rows,
        [2.7, 1.7, 1.8, 2.2, 2.7, 5.4], font_size=7.0,
    )
    sup.add_paragraph("Panel C. Feature-variance handling and numerical policy.", style="Caption")
    add_table(
        sup,
        ["Representation", "Dimensions", "Constant", "Near constant", "Filtering", "Handling and failure policy"],
        [[display_representation(r["foundation_model"]), r["dimensions"],
          r["constant_features"], r["near_constant_features"], r["variance_filtering"],
          f"{r['handling_in_pls']}; {r['numerical_failure_policy']}"]
         for r in foundation_binary_component_features],
        [2.6, 1.5, 1.5, 1.8, 1.5, 8.0], font_size=6.8,
    )
    sup.add_paragraph(
        "Near constant was defined as a full-cohort standard deviation greater than zero and at most 1e-8. The five constant Giga-SSL dimensions were retained to preserve the released 512-feature schema. Training-fold centering maps them to zero, so they contribute no covariance. The pipeline failed closed and did not substitute another estimator."
    )
    sup.add_paragraph("Panel D. Paired TITAN and Prov-GigaPath comparison. Their reported pretraining corpora excluded TCGA.", style="Caption")
    add_table(
        sup,
        ["Pairs", "Spearman 1-10/1-20", "Median TITAN minus Prov AUROC 1-10/1-20", "TITAN higher 1-10/1-20", "Prov higher 1-10/1-20", "Pairwise leader changed"],
        [[foundation_titan_prov_component20["tasks"],
          f"{fnum(foundation_titan_prov_component20['primary_spearman'], 3)}/{fnum(foundation_titan_prov_component20['expanded_spearman'], 3)}",
          f"{fnum(foundation_titan_prov_component20['primary_median_TITAN_minus_ProvGigaPath'], 3)}/{fnum(foundation_titan_prov_component20['expanded_median_TITAN_minus_ProvGigaPath'], 3)}",
          f"{foundation_titan_prov_component20['primary_TITAN_higher']}/{foundation_titan_prov_component20['expanded_TITAN_higher']}",
          f"{foundation_titan_prov_component20['primary_ProvGigaPath_higher']}/{foundation_titan_prov_component20['expanded_ProvGigaPath_higher']}",
          foundation_titan_prov_component20["pairwise_leader_changed"]]],
        [1.2, 2.7, 4.2, 2.5, 2.5, 2.5], font_size=6.8,
    )
    if foundation_component_range:
        sup.add_paragraph(
            f"The earlier fixed 47-target sensitivity is retained only as a companion analysis for 35 binary and 12 continuous pairs. Its leading representation remained unchanged for {foundation_component_winner_summary['binary']['retained']}/35 binary and {foundation_component_winner_summary['continuous']['retained']}/12 continuous pairs. The complete 366-pair binary analysis above supersedes the fixed-subset binary result for evaluating component-range sensitivity."
        )
if translational_consensus_family:
    sup.add_heading("Table S15d. Cross-representation consensus by endpoint class", 2)
    sup.add_paragraph("Counts use effect-threshold crossings on the common patient cohort. ‘Unique’ means that only the named representation crossed the threshold under the specified PLS regression/PLS-LDA probe; it does not establish biological specificity or external validity.")
    add_table(
        sup,
        ["Outcome", "Family", "All three", "Two", "TITAN only", "Giga-SSL only", "Prov-GigaPath only", "No crossing"],
        [[r["outcome_type"], r["family"], r["retained_all_three"], r["retained_two"],
          r["unique_TITAN"], r["unique_GigaSSL"], r["unique_ProvGigaPath"], r["no_crossing"]]
         for r in translational_consensus_family],
        [2.0, 3.8, 1.6, 1.4, 1.8, 2.0, 2.4, 1.8],
    )
if foundation_exclusion_inventory:
    sup.add_heading("Table S15e. Representative pathology foundation models not included in the matched artifact benchmark", 2)
    sup.add_paragraph("The benchmark was pragmatic rather than exhaustive. Inclusion required an accessible, ready-to-use, fixed-length slide-level TCGA embedding artifact with deterministic slide identifiers, sufficient 32-cancer common-cohort coverage and no need to download or reprocess WSI pixels. Exclusion does not imply lower model quality. The complete machine-readable inventory records official source URLs, assessment date and scope caveats.")
    add_table(
        sup,
        ["Model or family", "Representation level", "Reason not included", "Criterion not met"],
        [[r["model_or_family"], r["representation_level"], r["reason_not_included"], r["criterion_not_met"]]
         for r in foundation_exclusion_inventory],
        [3.4, 3.0, 9.0, 4.6],
    )
if titan_prov_paired:
    sup.add_heading("Table S15f. Dedicated paired TITAN–Prov-GigaPath summary", 2)
    sup.add_paragraph("The reported pretraining corpora of both pipelines excluded TCGA. Counts and effect differences are derived from the existing 8,241-patient matched results without model refitting. Δ is Prov-GigaPath minus TITAN. Crossing thresholds are Q²≥0.20 for continuous tasks and AUROC≥0.60 for binary tasks. The comparison still includes pipeline-specific preprocessing, resolution, architecture and released layer and therefore does not isolate foundation-model quality.")
    add_table(
        sup,
        ["Outcome", "Tasks", "Both / TITAN only / Prov-GigaPath only / neither", "Higher effect TITAN / Prov-GigaPath / ties", "Median Δ (95% cancer-cluster interval)", "Spearman"],
        [[r["outcome_type"], r["targets"],
          f"{r['both_effect_threshold_crossing']} / {r['TITAN_only_crossing']} / {r['ProvGigaPath_only_crossing']} / {r['neither_crossing']}",
          f"{r['TITAN_higher_effect']} / {r['ProvGigaPath_higher_effect']} / {r['tied_effect']}",
          f"{fnum(r['median_delta_ProvGigaPath_minus_TITAN'], 3)} ({fnum(r['cluster_bootstrap_low'], 3)} to {fnum(r['cluster_bootstrap_high'], 3)})",
          fnum(r["spearman_effect"], 3)] for r in titan_prov_paired],
        [2.1, 1.6, 5.4, 4.5, 4.5, 1.8],
    )
if foundation_fold_summary and foundation_consensus_stability:
    sup.add_heading("Table S15g. Fold-assignment and threshold stability of the matched three-representation atlas", 2)
    sup.add_paragraph(f"This audit used five new matched nested partitions for all {foundation_union_counts['tasks']} tasks with an effect-threshold crossing in at least one representation and every task within 0.05 of Q²=0.20 or AUROC=0.60 for at least one representation; their union comprised {len(foundation_fold_selection)} unique pairs. Patients, folds, seeds and tuning rules were identical across representations within each task and repeat. Stable means an effect-threshold crossing in all five new partitions, variable means one to four and never means zero. These are descriptive internal partition-sensitivity estimates rather than representation-specific permutation/FDR results or external validation.")
    add_table(
        sup,
        ["Representation", "Outcome", "Selected tasks", "Stable / variable / never", "Mean effect-threshold-crossing proportion", "Median agreement with primary call"],
        [[display_representation(r["foundation_model"]), r["outcome_type"], r["selected_tasks"],
          f"{r['stable_crossing_tasks']} / {r['variable_crossing_tasks']} / {r['never_crossing_tasks']}",
          fnum(r["mean_crossing_proportion"], 3), fnum(r["median_primary_repeat_agreement"], 3)]
         for r in foundation_fold_summary],
        [3.0, 2.2, 2.2, 3.3, 3.2, 3.6],
    )
    consensus_grouped = defaultdict(list)
    for r in foundation_consensus_stability:
        consensus_grouped[(r["outcome_type"], r["primary_consensus_class"])].append(r)
    sup.add_paragraph("Panel B. Stability of the primary threshold-derived support class. Agreement is the proportion of five alternative partitions retaining the same all-three/exactly-two/representation-specific/none class. This is a catalogue-navigation summary, not an evidence grade. The complete file also reports exact support patterns and modal-class ties.", style="Caption")
    add_table(
        sup,
        ["Outcome", "Primary class", "Tasks", "Median agreement", "Class retained in all five"],
        [[outcome, cls, len(group),
          fnum(statistics.median(float(r["primary_consensus_agreement_proportion"]) for r in group), 3),
          sum(float(r["primary_consensus_agreement_proportion"]) == 1.0 for r in group)]
         for (outcome, cls), group in sorted(consensus_grouped.items())],
        [2.2, 4.0, 1.8, 3.0, 3.2],
    )
    sup.add_paragraph("Panel C. Threshold sensitivity. The complete machine-readable curves report every repeat at Q² thresholds 0.10-0.30 and AUROC thresholds 0.55-0.65; categorical support-pattern curves are supplied separately. Continuous paired effect and rank summaries are provided without thresholding.", style="Caption")
    selected_curve_rows = []
    for r in foundation_threshold_stability:
        threshold = float(r["threshold"])
        wanted = ((r["outcome_type"] == "continuous" and round(threshold, 2) in {0.10, 0.20, 0.30}) or
                  (r["outcome_type"] == "binary" and round(threshold, 2) in {0.55, 0.60, 0.65}))
        if wanted and int(r["stability_repeat"]) == 1:
            selected_curve_rows.append(r)
    add_table(
        sup,
        ["Representation", "Outcome", "Threshold", "Mean crossings (range)", "Mean selected-task proportion"],
        [[display_representation(r["foundation_model"]), r["outcome_type"], fnum(r["threshold"], 2),
          f"{fnum(r['mean_crossings'], 1)} ({r['min_crossings']}–{r['max_crossings']})",
          fnum(r["mean_crossing_proportion"], 3)] for r in selected_curve_rows],
        [3.0, 2.1, 2.0, 3.6, 3.5],
    )
if foundation_tss_summary and foundation_robustness:
    sup.add_heading("Table S15h. Multi-representation tissue-source-site-code sensitivity fields", 2)
    sup.add_paragraph(
        f"All {foundation_union_counts['tasks']} cancer-endpoint pairs with an effect-threshold crossing in at least one representation were rerun for TITAN, Giga-SSL and Prov-GigaPath while keeping complete two-character TCGA tissue-source-site codes together in both outer and inner validation. Within each task, all representations used the same patients, code-grouped folds, seeds and tuning rules. Of {len(foundation_tss_grouped):,} representation-task fits, {len(foundation_tss_feasible_rows):,} were estimable. The three ACC genome-doubling fits were not estimable because one grouped inner training partition contained a single class. Matched-random controls reproduced every outer-fold size and, for binary tasks, every positive/negative class count. Metrics were calculated once from pooled outer out-of-fold predictions, not by averaging fold-specific metrics. Grouped effects, matched-random effects, their paired difference, threshold-derived support pattern, sample-size stratum and grouped-fold adequacy are separate fields. This is sensitivity to grouping by a barcode-derived cohort-structure variable, not institutional or scanner-level validation."
    )
    add_table(
        sup,
        ["Representation", "Outcome", "Grouped evaluable, n/N", "Primary effect-threshold crossings", "Retained after grouping, n/N (%)", "Median grouped−primary operating metric", "Median grouped−matched-random effect"],
        [[display_representation(r["foundation_model"]), r["outcome_type"],
          f"{r['grouped_evaluable']}/{r['tasks']}", r["primary_crossings"],
          f"{r['retained_primary_crossings']}/{r['primary_crossings']} ({fnum(r['retention_percent'], 1)}%)",
          fnum(r["median_grouped_minus_primary_operating_metric"], 3),
          fnum(r["median_grouped_minus_matched_effect"], 3)]
         for r in foundation_tss_summary],
        [2.7, 1.8, 2.2, 2.2, 3.2, 3.3, 3.3],
    )
    sup.add_paragraph("Panel B. Primary consensus class versus retention of the originally crossing representations.", style="Caption")
    add_table(
        sup,
        ["Outcome", "Primary consensus", "Complete / partial / none"],
        [[outcome, consensus,
          f"{foundation_tss_consensus_counts[(outcome, consensus, 'complete retention')]} / {foundation_tss_consensus_counts[(outcome, consensus, 'partial retention')]} / {foundation_tss_consensus_counts[(outcome, consensus, 'no retention')]}" ]
         for outcome in ("continuous", "binary")
         for consensus in ("all three", "exactly two", "representation specific")],
        [2.5, 4.0, 4.0],
    )
    sup.add_paragraph("Panel C. Deprecated R1–R4 registry navigation tags retained for backward compatibility. These composites are not used in the main scientific hierarchy and must not be interpreted as evidence grades.", style="Caption")
    add_table(
        sup,
        ["Class", "Definition", "Tasks", "Tasks with sparse-fold flag"],
        [
            ["R1", "Legacy: all three representations; larger-sample stratum; complete grouped retention", foundation_robustness_class_counts["R1: all-three, mature, complete grouped retention"], foundation_tss_adequacy_class_by_key["R1"]["tasks_with_sparse_grouped_folds"]],
            ["R2", "Legacy: at least two representations; larger-sample stratum; complete grouped retention", foundation_robustness_class_counts["R2: multi-representation, mature, complete grouped retention"], foundation_tss_adequacy_class_by_key["R2"]["tasks_with_sparse_grouped_folds"]],
            ["R3", "Legacy: larger-sample stratum; at least one original crossing retained", foundation_robustness_class_counts["R3: mature with partial or single-representation retention"], foundation_tss_adequacy_class_by_key["R3"]["tasks_with_sparse_grouped_folds"]],
            ["R4", "Legacy: smaller-sample stratum or no original crossing retained after grouping", foundation_robustness_class_counts["R4: limited or cohort-structure-sensitive internal evidence"], foundation_tss_adequacy_class_by_key["R4"]["tasks_with_sparse_grouped_folds"]],
        ],
        [1.3, 7.6, 1.5, 2.7],
    )
    sup.add_paragraph("The sparse-fold flag is deliberately orthogonal to the deprecated R1–R4 tag. A task is flagged when fewer than five outer folds were realised, an outer test fold contained fewer than 10 patients, a binary outer test/inner validation/inner training fold contained one class, or an outer/inner binary training fit contained fewer than 20 patients in either class. These are descriptive audit triggers, not exclusion or validity thresholds.")
if foundation_evidence_maturity:
    sup.add_heading("Table S15i. Inclusive and sample-size-stratified crossing counts", 2)
    sup.add_paragraph(
        "The inclusive matched atlas uses n≥50 for continuous tasks and at least 20 patients per binary class. The larger-sample stratum requires n≥100 for continuous tasks or at least 50 patients per binary class. It is a denominator descriptor—not an evidence grade or retrospective significance filter—and does not change task eligibility, thresholds, permutation/FDR status or the complete atlas. Matched three-representation crossings remain descriptive because representation-specific permutation/FDR testing was not performed.",
        style="Caption",
    )
    add_table(
        sup,
        ["Representation", "Outcome", "Inclusive eligible", "Inclusive crossings", "Larger-sample eligible", "Larger-sample crossings", "Smaller-sample crossings"],
        [[display_representation(r["foundation_model"]), r["outcome_type"],
          r["inclusive_eligible_tasks"], r["inclusive_crossings"],
          r["standard_evidence_eligible_tasks"],
          f"{r['standard_evidence_crossings']} ({fnum(r['standard_evidence_crossing_percent_of_standard_eligible'], 1)}%)",
          r["limited_evidence_crossings"]]
         for r in foundation_evidence_maturity],
        [2.7, 2.0, 2.3, 2.5, 2.4, 3.0, 2.3],
    )
    sup.add_paragraph(
        f"In the separately permutation/FDR-filtered TITAN layer, {ival(titan_maturity_by_outcome['continuous']['standard_evidence_candidates'])}/219 continuous candidates met n≥100 and {ival(titan_maturity_by_outcome['binary']['standard_evidence_candidates'])}/104 binary candidates met at least 50 patients per class. The 13 continuous and 17 binary smaller-sample candidates remain in the complete results but are excluded from default inference."
    )
if foundation_effect_partition_audit:
    sup.add_heading("Table S15j. Continuous effect, alternative-partition and rank-stability audit", 2)
    sup.add_paragraph("The complete 1,680-row machine-readable audit reports primary Q²/AUROC, alternative-partition median and interquartile range, crossing proportion, primary-winner repeat proportion, grouped effect, matched-random effect, grouped-minus-matched-random difference and sample-size stratum. The compact summary below does not assign evidence grades.", style="Caption")
    summary_rows = []
    for model in ("TITAN", "GigaSSL", "ProvGigaPath"):
        for outcome in ("continuous", "binary"):
            group = [r for r in foundation_effect_partition_audit
                     if r.get("foundation_model") == model and r.get("outcome_type") == outcome]
            grouped_group = [r for r in group if r.get("grouped_minus_matched_effect") not in (None, "", "NA")]
            summary_rows.append([
                display_representation(model), outcome, len(group),
                fnum(median(r.get("primary_effect") for r in group), 3),
                fnum(median(r.get("repeat_effect_median") for r in group), 3),
                fnum(median(r.get("crossing_proportion") for r in group), 3),
                fnum(median(r.get("grouped_minus_matched_effect") for r in grouped_group), 3),
                sum(r.get("sample_size_stratum") == "larger-sample" for r in group),
            ])
    add_table(sup, ["Representation", "Outcome", "Pairs", "Median primary effect", "Median repeat effect", "Median crossing proportion", "Median grouped−matched", "Larger-sample pairs"], summary_rows,
              [2.8, 2.0, 1.5, 3.0, 3.0, 3.4, 3.2, 2.6])
if foundation_tss_fold_adequacy_summary and titan_site_fold_adequacy_summary:
    sup.add_heading("Table S15k. Grouped-fold adequacy audit", 2)
    sup.add_paragraph("The primary matched benchmark and the supporting TITAN permutation/FDR-filtered screen use different task universes; they are therefore summarized separately. 'Single-class outer' means at least one outer test fold contained only positive or only negative patients. 'Single-class inner validation/training' is defined analogously within component-selection folds. Outer metrics and inner tuning statistics were calculated from pooled out-of-fold predictions rather than averages of fold-specific metrics. The complete task-, outer-fold- and inner-fold-level files identify every four-fold task, class minimum and audit reason.", style="Caption")
    adequacy_rows = []
    for r in foundation_tss_fold_adequacy_summary:
        adequacy_rows.append([
            "Matched three-representation", r["outcome_type"], r["tasks"],
            f"{r['minimum_outer_test_n']}–{r['maximum_outer_test_n']}",
            r["tasks_with_four_outer_folds"],
            r["tasks_with_outer_test_n_below_10"],
            r["tasks_with_single_class_outer_test_fold"],
            f"{r['tasks_with_single_class_inner_validation_fold']}/{r['tasks_with_single_class_inner_training_fold']}",
            r["tasks_with_sparse_grouped_folds"],
        ])
    for r in titan_site_fold_adequacy_summary:
        adequacy_rows.append([
            "Supporting TITAN screen", r["outcome_type"], r["models"],
            f"{r['minimum_outer_test_n']}–{r['maximum_outer_test_n']}",
            r["models_with_four_outer_folds"],
            r["models_with_outer_test_n_below_10"],
            r["models_with_single_class_outer_test_fold"],
            f"{r['models_with_single_class_inner_validation_fold']}/{r['models_with_single_class_inner_training_fold']}",
            r["models_with_sparse_grouped_folds"],
        ])
    add_table(
        sup,
        ["Analysis layer", "Outcome", "Tasks/models", "Outer test n range", "Four-fold", "Outer test n<10", "Single-class outer", "Single-class inner validation/training", "Sparse-fold flag"],
        adequacy_rows,
        [3.2, 1.7, 1.8, 2.2, 1.5, 2.0, 2.2, 3.3, 2.0],
        font_size=7.0,
    )
    sup.add_paragraph("In the matched benchmark, minimum binary outer-training counts were 1 positive and 5 negative patients, and minimum inner-training counts were 0 positive and 1 negative patient. In the supporting TITAN screen, the corresponding minima were 7/12 and 2/3. The one-class inner training split made the matched ACC genome-doubling task non-estimable for all three representations. Its failure is retained rather than replaced by a fallback result.")
if foundation_slide_audit and foundation_exact_slide_sensitivity:
    sup.add_heading("Table S16. Exact slide-set audit and exact-common-slide sensitivity", 1)
    sup.add_paragraph(
        f"Within the 8,241-patient common cohort, TITAN, Giga-SSL and Prov-GigaPath contributed {ival(foundation_slide_audit.get('titan_slides_common_patients')):,}, {ival(foundation_slide_audit.get('gigassl_slides_common_patients')):,} and {ival(foundation_slide_audit.get('provgigapath_slides_common_patients')):,} slides, respectively. Exact within-patient slide sets agreed for {ival(foundation_slide_audit.get('identical_slide_set_patients')):,} patients; 34 differed. The exact three-way intersection contained {ival(foundation_slide_audit.get('exact_common_slides')):,} slides and retained every patient."
    )
    add_table(
        sup,
        ["Representation", "Outcome", "Tasks", "Primary effect-threshold crossings", "Exact-slide effect-threshold crossings", "Lost/gained", "Median Δ", "IQR Δ", "Spearman"],
        [[r["foundation_model"], r["outcome_type"], r["tasks"],
          r["primary_screening_positive"], r["exact_screening_positive"],
          f"{r['lost_threshold']}/{r['gained_threshold']}", fnum(r["median_delta"], 4),
          f"{fnum(r['q1_delta'], 4)} to {fnum(r['q3_delta'], 4)}",
          fnum(r["spearman_primary_exact"], 3)] for r in foundation_exact_slide_sensitivity],
        [3.2, 2.4, 1.7, 2.6, 2.4, 2.0, 1.8, 3.0, 2.0],
    )
    sup.add_paragraph("Machine-readable companions report every patient's representation-specific slide counts, the complete slide-count-difference distribution, and task-level primary versus exact-common-slide estimates. Changes in threshold membership were concentrated near the documented screening boundary.")
if foundation_family_summary and foundation_cancer_summary:
    sup.add_heading("Table S17. Catalogue-normalized breadth and foundation-model comparison by endpoint family, cancer and retained programme", 1)
    family_top_rows = []
    cancer_top_rows = []
    endpoint_top_rows = []
    programme_top_rows = []
    for model in ("TITAN", "GigaSSL", "ProvGigaPath"):
        for outcome in ("continuous", "binary"):
            family_top_rows.extend(sorted(
                [r for r in foundation_family_summary if r["foundation_model"] == model and r["outcome_type"] == outcome],
                key=lambda r: ival(r["effect_threshold_crossings"]), reverse=True)[:3])
            cancer_top_rows.extend(sorted(
                [r for r in foundation_cancer_summary if r["foundation_model"] == model and r["outcome_type"] == outcome],
                key=lambda r: ival(r["effect_threshold_crossings"]), reverse=True)[:3])
            endpoint_top_rows.extend(sorted(
                [r for r in foundation_endpoint_retention if r["foundation_model"] == model and r["outcome_type"] == outcome],
                key=lambda r: (ival(r["retained_cancers"]), float(r["retained_cancer_percent"])), reverse=True)[:2])
            programme_top_rows.extend(sorted(
                [r for r in foundation_programme_retention if r["foundation_model"] == model and r["outcome_type"] == outcome],
                key=lambda r: (ival(r["retained_cancers"]), float(r["retained_cancer_percent"])), reverse=True)[:2])
    sup.add_paragraph("Panel A. Catalogue-normalized breadth. Effect-threshold-crossing counts, unique definitions and macro rates use Q²≥0.20 for continuous tasks and AUROC≥0.60 for binary tasks. Macro rates are unweighted means of within-stratum percentages. Counts are catalogue-dependent and are not independent biological discoveries.", style="Caption")
    add_table(
        sup,
        ["Representation", "Outcome", "Task effect-threshold crossings", "Unique definitions", "Macro family %", "Macro cancer %", "Largest family share"],
        [[display_representation(r["foundation_model"]), r["outcome_type"],
          f"{r['task_crossings']}/{r['eligible_tasks']} ({fnum(r['task_crossing_percent'], 1)}%)",
          f"{r['endpoint_definitions_crossing']}/{r['eligible_endpoint_definitions']} ({fnum(r['endpoint_definition_crossing_percent'], 1)}%)",
          fnum(r["macro_family_crossing_percent"], 1), fnum(r["macro_cancer_crossing_percent"], 1),
          f"{r['largest_crossing_family']}: {r['largest_family_crossings']}/{r['task_crossings']} ({fnum(r['largest_family_share_of_crossings'], 1)}%)"]
         for r in sorted(foundation_normalized_breadth, key=lambda x: (x["foundation_model"], x["outcome_type"]))],
        [2.5, 1.8, 2.5, 2.7, 2.0, 2.0, 3.7],
    )
    sup.add_paragraph("Panel B. Three endpoint families with the most effect-threshold crossings within each representation and outcome type. The complete stratification is machine readable.", style="Caption")
    add_table(
        sup,
        ["Representation", "Outcome", "Family", "Eligible", "Effect-threshold crossings", "Crossing %", "Median effect"],
        [[r["foundation_model"], r["outcome_type"], r["family"], r["eligible_tasks"],
          r["effect_threshold_crossings"], fnum(r["crossing_percent"], 1), fnum(r["median_effect"], 3)]
         for r in family_top_rows],
        [3.0, 2.0, 4.2, 1.8, 2.0, 2.2, 2.5],
    )
    sup.add_paragraph("foundation_model_cancer_summary.csv, foundation_model_endpoint_cancer_retention.csv and foundation_model_programme_cancer_retention.csv contain every cancer, exact endpoint definition and biological-programme summary. These exhaustive catalogue records were moved out of the PDF.")
    sup.add_paragraph("The matched atlas contains 187 exact endpoint definitions (56 continuous and 131 binary) from the 194 definitions in the complete 2,073-task TITAN universe. Raw task crossings quantify breadth within this catalogue and must not be interpreted as independent biological discoveries.")
sup.add_heading("Table S18. Endpoint-provenance stratification, same-H&E sensitivity and translational examples", 1)
sup.add_paragraph("Panel A. Complete matched-atlas stratification by reference-label provenance. CIBERSORT fractions, methylation-derived leukocyte fractions and RNA signatures represent agreement with computational phenotypes rather than recovery of directly measured immune-cell abundance.", style="Caption")
add_table(
    sup,
    ["Representation", "Outcome", "Measurement class", "Eligible", "Crossings", "Crossing %", "Unique definitions crossing"],
    [[display_representation(r["foundation_model"]), r["outcome_type"], r["measurement_class"],
      r["eligible_tasks"], r["effect_threshold_crossings"], fnum(r["crossing_percent"], 1),
      f"{r['unique_definitions_crossing']}/{r['unique_endpoint_definitions']} ({fnum(r['unique_definition_crossing_percent'], 1)}%)"]
     for r in sorted(foundation_provenance_summary, key=lambda x: (x["outcome_type"], x["measurement_class"], x["foundation_model"]))],
    [2.3, 1.6, 4.4, 1.6, 1.8, 2.0, 3.2], font_size=7.0,
)
sup.add_paragraph("Panel B. Sensitivity excluding same-H&E TIL Regional Fraction. The full 2,073-task endpoint catalogue contained 13 eligible same-H&E tasks; 11 met matched common-cohort eligibility and crossed in all three representations.", style="Caption")
add_table(
    sup,
    ["Representation", "Continuous all", "Continuous excluding same-H&E", "All matched", "All matched excluding same-H&E"],
    [[display_representation(r["foundation_model"]),
      f"{r['all_continuous_crossings']}/{r['all_continuous_tasks']} ({fnum(r['all_continuous_crossing_percent'], 1)}%)",
      f"{r['cross_modal_continuous_crossings']}/{r['cross_modal_continuous_tasks']} ({fnum(r['cross_modal_continuous_crossing_percent'], 1)}%)",
      f"{r['all_matched_crossings']}/{r['all_matched_tasks']}",
      f"{r['matched_crossings_excluding_same_histology']}/{r['matched_tasks_excluding_same_histology']}"]
     for r in sorted(foundation_same_histology, key=lambda x: x["foundation_model"])],
    [2.5, 3.2, 4.1, 2.3, 4.1], font_size=7.1,
)
sup.add_paragraph("Panel C. Two leading mature all-three, complete-grouped-retention examples within each provenance class, ranked by the minimum primary effect across the three representations. These are internal prioritisation examples, not externally validated biomarkers.", style="Caption")
synthesis_top_rows = []
for cls in sorted(set(r["measurement_class"] for r in foundation_biological_synthesis)):
    synthesis_top_rows.extend([r for r in foundation_biological_synthesis if r["measurement_class"] == cls][:2])
add_table(
    sup,
    ["Measurement class", "Cancer–endpoint", "n; pos/neg", "Primary effects G/P/T", "Grouped effects G/P/T", "Interpretation"],
    [[r["measurement_class"], f"{r['tumor_type']}–{r['endpoint']}",
      f"{r['n']}; {r['positive'] or '—'}/{r['negative'] or '—'}",
      f"{fnum(r['effect_GigaSSL'], 3)}/{fnum(r['effect_ProvGigaPath'], 3)}/{fnum(r['effect_TITAN'], 3)}",
      f"{fnum(r['grouped_effect_GigaSSL'], 3)}/{fnum(r['grouped_effect_ProvGigaPath'], 3)}/{fnum(r['grouped_effect_TITAN'], 3)}",
      r["interpretation_scope"]]
     for r in synthesis_top_rows],
    [3.7, 4.2, 2.0, 2.9, 2.9, 4.2], font_size=6.8,
)
add_portrait_section(sup)
sup.add_heading("Secondary single-outcome and multi-outcome PLS results", 1)
if pls2:
    text = []
    for r in pls2:
        text.append(f'{r["block"].replace("_", " ")}: mean cancer-level ΔQ² {fnum(r["mean_cancer_delta"])} (95% interval {fnum(r["ci_low"])} to {fnum(r["ci_high"])})')
    sup.add_paragraph("; ".join(text) + ". The intervals describe variation across cancers; interpretation is based on effect magnitude rather than endpoint win counts.")
sup.add_paragraph("The complete target-level and cancer-level comparison of separate single-outcome and joint multi-outcome PLS is available in pls1_vs_pls2_inflammation.csv. The two large exploratory figures were removed from the PDF.")
add_figure(sup, "FigureS5_continuous_reliability.png", "Figure S2. Continuous sample-size and repeat-stability audit. Panel A relates outcome-labelled sample size to five-repeat mean Q²; panel B relates sample size to mean pairwise Spearman stability of repeated out-of-fold predictions; panel C shows the 25 outer-fit component selections for each candidate with fewer than 100 patients. The dashed line marks the ten-component ceiling. The <100-patient label defines only the smaller-sample stratum and does not alter the complete atlas.")
if foundation_fold_summary:
    add_figure(sup, "Figure3_foundation_model_consensus_retention.png", "Figure S3. Threshold-derived consensus categories and retention with complete TCGA tissue-source-site codes held apart. The categories are provided only for catalogue navigation. They are sensitive to the pragmatic Q² and balanced-accuracy thresholds and must not be interpreted as biological or clinical evidence grades. Continuous effects, alternative-partition variability, ranks and grouped-minus-matched-random changes are shown in main Figure 3 and Table S15j.")
add_figure(sup, "Figure6_site_grouped_sensitivity.png", f"Figure S4. Supporting TITAN-layer sensitivity to grouping by TCGA tissue-source-site code. Panel A compares all {len(site_c) + len(site_b)} random-fold estimates with estimates obtained when complete codes were held apart; Panel B shows the six largest attenuations; Panel C shows the 10 strongest chance-normalized code-classification results. The code is not an institution, scanner or laboratory identifier, and attenuation does not by itself establish technical confounding.")
sup.add_paragraph("The main manuscript shows the continuous and mutation sections of the PathoFMPred output for the two COAD patients. The Supplement retains high-resolution companions. coad_pathofmpred_multifoundation_predictions.csv, coad_pathofmpred_multifoundation_mutation_predictions.csv and Additional files 2 and 3 contain the original values and separate TITAN software reports.")
add_figure(sup, "Figure2_foundation_model_breadth_effect.png", "Figure S5. Representation-specific effect-threshold-crossing proportions by tumour-feature class. Direct alterations, derived reference phenotypes and the same-H&E TIL fraction are displayed separately. Colours and representation order match the main figures. These catalogue-dependent summaries are descriptive and are not independent biological discoveries or representation-specific permutation/FDR results.")
add_figure(sup, "FigureS12_paired_representation_effects.png", "Figure S6. Paired target-level performance across all 1,933 matched cancer-endpoint tasks. Each point compares the Q² of a continuous task or AUROC of a binary task between TITAN and one alternative released representation. Identity lines indicate equal performance. These descriptive paired distributions do not provide representation-specific permutation or multiplicity results and do not establish intrinsic foundation-model superiority.")
add_figure(sup, "FigureS13_winner_rank_stability.png", "Figure S7. Stability of the primary leading-representation rank across five alternative matched partitions. The distribution is retained as a full-resolution sensitivity display rather than a principal manuscript panel.")
sup.add_heading("Post hoc PathoFMPred software illustration", level=1)
sup.add_paragraph(
    "We applied PathoFMPred to TITAN, Giga-SSL and Prov-GigaPath inputs for two COAD patients, TCGA-AA-A01F and TCGA-A6-A56B. We selected the pair post hoc after restricting the candidate set to cases with comparable reported pathology and limited profile saturation, then maximizing separation across their displayed continuous profiles. The selection demonstrates the software interface only. It is not representative sampling, calibration, treatment-response analysis, external validation or clinical interpretation."
)
sup.add_paragraph(
    f"PathoFMPred returned 15 predictable continuous endpoints for TITAN, 12 for Giga-SSL and 14 for Prov-GigaPath. Ten endpoints were shared by all three fitted resources: the lymphocyte-infiltration signature, TIL Regional Fraction, MANTIS score, Taylor aneuploidy score, immune-atlas aneuploidy score, macrophage-regulation signature, SNV neoantigens, allograft-rejection pathway activity, IL6-JAK-STAT3 pathway activity and interferon-gamma-response pathway activity. Representation-specific additions included deleted-arm count and leukocyte fraction for Giga-SSL; those two endpoints plus MSIsensor score and interferon-alpha-response pathway activity for Prov-GigaPath; and MSIsensor score, silent and nonsilent mutation rates, interferon-alpha-response pathway activity and myogenesis pathway activity for TITAN. For TCGA-AA-A01F, TITAN/Giga-SSL/Prov-GigaPath predicted MANTIS scores of {fnum(coad_multifoundation_by_key[('TCGA-AA-A01F', 'TITAN', 'MANTIS score')]['prediction'])}/{fnum(coad_multifoundation_by_key[('TCGA-AA-A01F', 'GigaSSL', 'MANTIS score')]['prediction'])}/{fnum(coad_multifoundation_by_key[('TCGA-AA-A01F', 'ProvGigaPath', 'MANTIS score')]['prediction'])}; for TCGA-A6-A56B, they predicted {fnum(coad_multifoundation_by_key[('TCGA-A6-A56B', 'TITAN', 'MANTIS score')]['prediction'])}/{fnum(coad_multifoundation_by_key[('TCGA-A6-A56B', 'GigaSSL', 'MANTIS score')]['prediction'])}/{fnum(coad_multifoundation_by_key[('TCGA-A6-A56B', 'ProvGigaPath', 'MANTIS score')]['prediction'])}. Original predicted values in source endpoint units appear at every radar vertex. The radius is an internal TCGA reference percentile used only to place differently scaled continuous outputs on one plot."
)
add_figure(
    sup, "Figure3_COAD_PathoFMPred_multifoundation_examples.png",
    "Figure S8. High-resolution companion to main Figure 5. This post hoc PathoFMPred illustration uses TITAN, Giga-SSL and Prov-GigaPath inputs for TCGA-AA-A01F and TCGA-A6-A56B. Each panel includes only endpoints predictable for that representation, so the axes intentionally differ. Corner labels show original predictions in source units. Radius shows an internal TCGA reference percentile for display only, not a probability or clinical reference interval. The figure does not provide calibration, treatment-response evidence, external validation or clinical interpretation.",
    width=6.55,
)
sup.add_paragraph(
    "APC, KRAS and TP53 were the predictable mutation endpoints available through the default PathoFMPred interface for all three representations. For TCGA-AA-A01F, every representation called APC and TP53 wild type, while Giga-SSL alone called KRAS mutated. For TCGA-A6-A56B, every representation called APC mutated; Giga-SSL and Prov-GigaPath called KRAS mutated; and TITAN and Prov-GigaPath called TP53 mutated. The uncalibrated reference-score ranks differed across representations. These ranks describe position in the internal TCGA out-of-fold score distribution and are not probabilities. Raw LDA scores remain on model-specific scales and should not be compared numerically across representations. The processed mutation outcome table contained no APC, KRAS or TP53 reference label for either illustrative patient, so this example demonstrates model output and agreement only, not correctness."
)
add_figure(
    sup, "Figure6_COAD_PathoFMPred_full_binary_output.png",
    "Figure S9. High-resolution companion to main Figure 6. Predictable mutation outputs for the two post hoc COAD PathoFMPred software examples. Cells report the fitted LDA class call, internal TCGA reference-score rank and original LDA score for APC, KRAS and TP53 using TITAN, Giga-SSL and Prov-GigaPath inputs. The rank is not a probability, the LDA scores are model-specific and the processed mutation table contains no reference APC, KRAS or TP53 label for these patients. The figure therefore does not evaluate prediction correctness, calibration, treatment response, external validation or clinical utility.",
    width=6.55,
)
sup.add_heading("Machine-readable additional files", 1)
chronology_item = sup.add_paragraph("data/reference/analysis_chronology.csv", style="List Bullet")
chronology_item.paragraph_format.space_after = Pt(0)
chronology_item.paragraph_format.line_spacing = 1.2
for name in ["data/reference/model_inventory_by_representation_family.csv", "data/reference/software_access_licensing_matrix.csv", "data/reference/foundation_model_exclusion_inventory.csv", "data/reference/titan_provgigapath_paired_summary.csv", "fitted_model_inventory_reconciliation.csv", "fitted_model_target_universe_audit.csv"]:
    p = sup.add_paragraph(name, style="List Bullet")
    p.paragraph_format.space_after = Pt(0)
    p.paragraph_format.line_spacing = 1.2
for name in ["data/reference/translational_consensus_target_audit.csv", "data/reference/translational_consensus_by_endpoint_family.csv", "data/reference/translational_consensus_main_examples.csv"]:
    p = sup.add_paragraph(name, style="List Bullet")
    p.paragraph_format.space_after = Pt(0)
    p.paragraph_format.line_spacing = 1.2
lit_method_item = sup.add_paragraph("data/reference/literature_crosscheck_method.csv", style="List Bullet")
lit_method_item.paragraph_format.space_after = Pt(0)
lit_method_item.paragraph_format.line_spacing = 1.2
for name in ["continuous_reliability_by_model.csv", "continuous_reliability_by_sample_size.csv", "continuous_evidence_category_summary.csv", "continuous_limited_evidence_models.csv", "continuous_selected_components_by_fold.csv", "continuous_reliability_association_summary.csv"]:
    p = sup.add_paragraph(name, style="List Bullet")
    p.paragraph_format.space_after = Pt(0)
    p.paragraph_format.line_spacing = 1.2
for name in ["foundation_model_fold_stability_selection.csv", "foundation_model_fold_stability_repeats.csv", "foundation_model_fold_stability_summary.csv", "foundation_model_crossing_stability.csv", "foundation_model_consensus_stability.csv", "foundation_model_effect_rank_stability.csv", "foundation_model_winner_stability.csv", "foundation_model_pairwise_repeat_stability.csv", "foundation_model_threshold_sensitivity.csv", "foundation_model_threshold_consensus_sensitivity.csv", "foundation_model_fold_assignment_audit.csv", "results/predictions/foundation_model_fold_stability_oof.rds"]:
    p = sup.add_paragraph(name, style="List Bullet")
    p.paragraph_format.space_after = Pt(0)
    p.paragraph_format.line_spacing = 1.2
for name in ["foundation_model_tss_grouped_sensitivity.csv", "foundation_model_tss_grouped_fold_audit.csv", "foundation_model_tss_grouped_fold_adequacy.csv", "foundation_model_tss_grouped_outer_fold_composition.csv", "foundation_model_tss_grouped_inner_fold_composition.csv", "foundation_model_tss_grouped_fold_adequacy_summary.csv", "foundation_model_tss_grouped_fold_adequacy_by_deprecated_class.csv", "foundation_model_tss_grouped_summary.csv", "foundation_model_consensus_tss_crosstab.csv", "foundation_model_internal_robustness_classification.csv", "foundation_model_tss_code_only_outcomes.csv", "site_grouped_fold_adequacy_summary.csv"]:
    p = sup.add_paragraph(name, style="List Bullet")
    p.paragraph_format.space_after = Pt(0)
    p.paragraph_format.line_spacing = 1.2
for name in ["continuous_screen.csv", "binary_screen.csv", "foundation_model_cohort_audit.csv", "foundation_model_matched_screen.csv", "foundation_model_matched_summary.csv", "foundation_model_target_comparison.csv", "foundation_model_pairwise_summary.csv", "foundation_model_normalized_breadth_summary.csv", "foundation_model_endpoint_definition_coverage.csv", "foundation_model_endpoint_cancer_retention.csv", "foundation_model_programme_cancer_retention.csv", "foundation_model_provenance_stratified_summary.csv", "foundation_model_same_histology_sensitivity.csv", "foundation_model_translational_biological_synthesis.csv", "foundation_model_ridge_probe_subset.csv", "foundation_model_probe_ranking_sensitivity.csv", "foundation_model_probe_ranking_summary.csv", "foundation_model_pls_component_audit.csv", "foundation_model_feature_variance_audit.csv", "foundation_model_component_range_sensitivity.csv", "endpoint_dictionary.csv", "endpoint_definition_dictionary.csv", "endpoint_dictionary_summary.csv", "morphology_context_examples.csv", "morphology_context_model_summary.csv", "permutation_monte_carlo_uncertainty.csv", "targeted_permutation_refinement.csv", "targeted_permutation_refinement_targets.csv", "multiplicity_sensitivity_by_endpoint.csv", "multiplicity_sensitivity_summary.csv", "screen_positive_performance_summary.csv", "highlighted_model_performance.csv", "continuous_repeated_nested_cv.csv", "binary_repeated_nested_cv.csv", "continuous_repeated_oof_predictions.csv.gz", "binary_repeated_oof_predictions.csv.gz", "binary_minimum_class_sensitivity.csv", "binary_class_reliability_summary.csv", "binary_limited_evidence_models.csv", "binary_reliability_by_repeat.csv", "binary_outer_fold_class_counts.csv", "binary_selected_components_by_fold.csv", "binary_selected_component_distribution.csv", "binary_prediction_stability.csv", "binary_limited_evidence_learning_curve_repeats.csv", "binary_limited_evidence_learning_curve_folds.csv", "binary_limited_evidence_learning_curve_summary.csv", "binary_decision_rule_sensitivity.csv", "binary_decision_rule_sensitivity_summary.csv", "binary_decision_rule_membership_changes.csv", "binary_decision_rule_fold_thresholds.csv", "continuous_site_grouped_sensitivity.csv", "binary_site_grouped_sensitivity.csv", "site_grouped_retention_summary.csv", "site_grouped_models_below_effect_threshold.csv", "site_grouped_outer_fold_composition.csv", "site_grouped_fold_composition_summary.csv", "tissue_source_site_predictability_repeats.csv", "tissue_source_site_predictability_summary.csv", "tissue_source_site_partition_controls.csv", "tissue_source_site_partition_controls_summary.csv", "continuous_slide_pooling_sensitivity.csv", "binary_slide_pooling_sensitivity.csv", "continuous_median_pooling_sensitivity.csv", "binary_median_pooling_sensitivity.csv", "median_pooling_sensitivity_summary.csv", "slide_embedding_heterogeneity_patient_level.csv", "slide_embedding_heterogeneity_summary.csv", "slide_embedding_heterogeneity_maximum_slide_patient.csv", "sarc_maximum_slide_patient_exclusion_continuous.csv", "sarc_maximum_slide_patient_exclusion_binary.csv", "pathology_qc_field_availability.csv", "pathology_qc_narrative_audit.csv", "pathology_qc_patient_multiplicity_audit.csv", "pathology_qc_no_residual_patient_audit.csv", "pathology_qc_no_residual_patient_summary.csv", "nonadjudicated_no_residual_exclusion_all.csv", "nonadjudicated_no_residual_exclusion_continuous.csv", "nonadjudicated_no_residual_exclusion_binary.csv", "nonadjudicated_no_residual_exclusion_highlighted.csv", "nonadjudicated_no_residual_exclusion_summary.csv", "molecular_slide_linkage_audit.csv", "pls1_vs_pls2_inflammation.csv", "pls_vs_ridge_representative_sampling_frame.csv", "pls_vs_ridge_representative_jobs.csv", "pls_vs_ridge_representative_repeated_nested_cv.csv", "binary_symmetric_pls_ridge_representative_repeated_nested_cv.csv", "pls_vs_ridge_representative_paired_repeat_metrics.csv", "pls_vs_ridge_representative_matched_oof_predictions.csv.gz", "pls_vs_ridge_representative_models.csv", "pls_vs_ridge_representative_summary.csv", "pls_vs_ridge_representative_stratified_summary.csv", "prior_mutation_literature_crosswalk.csv", "prior_mutation_accuracy_comparison.csv", "supported_mutation_literature_audit.csv", "pan_cancer_benchmark_comparison.csv", "external_validation_locked_targets.csv", "coad_pathofmpred_multifoundation_predictions.csv", "coad_pathofmpred_multifoundation_mutation_predictions.csv", "slide_report_coverage_audit.csv", "patient_slide_multiplicity_by_cancer.csv", "participant_characteristics_by_cancer.csv", "tcga_cdr_match_audit.csv", "molecular_source_coverage_audit.csv", "mutation_coverage_audit.csv", "mutation_target_eligibility_audit.csv", "mutation_variant_classification_audit.csv", "source_manifest.csv", "software_manifest.csv", "models/model_registry.csv"]:
    p = sup.add_paragraph(name, style="List Bullet")
    p.paragraph_format.space_after = Pt(0)
    p.paragraph_format.line_spacing = 1.2
leadership_item = sup.add_paragraph(
    "foundation_model_biological_predictability_leadership.csv",
    style="List Bullet",
)
leadership_item.paragraph_format.space_after = Pt(0)
leadership_item.paragraph_format.line_spacing = 1.2
for name in ["foundation_model_binary_auroc_tuned_sensitivity.csv", "foundation_model_binary_auroc_tuned_folds.csv", "foundation_model_binary_auroc_tuned_summary.csv", "foundation_model_binary_estimand_comparison.csv", "results/predictions/foundation_model_binary_auroc_tuned_oof.rds"]:
    p = sup.add_paragraph(name, style="List Bullet")
    p.paragraph_format.space_after = Pt(0)
    p.paragraph_format.line_spacing = 1.2
for name in ["foundation_model_binary_component_range_20.csv", "foundation_model_binary_component_range_20_folds.csv", "foundation_model_binary_component_range_20_targets.csv", "foundation_model_binary_component_range_20_summary.csv", "foundation_model_binary_component_distribution.csv", "foundation_model_binary_component_feature_handling.csv", "foundation_model_TITAN_ProvGigaPath_binary_component_range.csv", "results/predictions/foundation_model_binary_component_range_20_oof.rds"]:
    p = sup.add_paragraph(name, style="List Bullet")
    p.paragraph_format.space_after = Pt(0)
    p.paragraph_format.line_spacing = 1.2
for name in ["multiplicity_denominator_audit.csv", "multiplicity_p_assignment_summary.csv", "multiplicity_denominator_summary.csv", "foundation_model_evidence_maturity.csv", "foundation_model_evidence_maturity_summary.csv", "titan_candidate_evidence_maturity.csv", "titan_candidate_evidence_maturity_summary.csv"]:
    p = sup.add_paragraph(name, style="List Bullet")
    p.paragraph_format.space_after = Pt(0)
    p.paragraph_format.line_spacing = 1.2


# Condense the PDF-facing Supplement. Exhaustive target-level, fold-level and
# model-level records remain in synchronized CSV and RDS companions. The DOCX
# retains methods, interpretation-critical summaries, the complete TRIPOD+AI
# map and the few figures that materially support the main article.
def _replace_after_heading(document, heading_text, builder):
    heading = _paragraph_exact(document, heading_text)._p
    parent = heading.getparent()
    node = heading.getnext()
    while node is not None and node.tag != qn("w:sectPr"):
        nxt = node.getnext()
        parent.remove(node)
        node = nxt
    builder()


def _compact_supp_contents():
    sup.add_paragraph(
        "This shortened Supplement retains interpretation-critical methods, compact "
        "three-representation biological summaries and four supporting figures. "
        "Complete target-level, fold-level and fitted-model records remain in the "
        "synchronized machine-readable companions."
    )
    for item in (
        "Supplementary Methods: outcome construction, validation, reliability, literature and endpoint provenance",
        "Tables S1-S3: cohort, pathology and molecular linkage",
        "Tables S4-S7: three-representation binary, continuous, family-level and literature summaries",
        "Tables S8-S13: statistical audits, endpoint provenance, matched benchmark, slide intersection and normalized breadth",
        "Figures S1-S4: binary reliability, continuous reliability, tissue-source-site-code sensitivity and paired representation effects",
        "Machine-readable companion inventory by analysis domain",
    ):
        sup.add_paragraph(item, style="List Bullet")


def _compact_supp_tables():
    add_table(
        sup,
        ["Layer", "Patients", "Cancer-endpoint tasks", "Representations", "Qualification"],
        [
            ["Matched benchmark", f"{foundation_common_n:,}", "3,389", "TITAN, Giga-SSL, Prov-GigaPath", "Descriptive Q2/AUROC comparison on matched patients and folds"],
            ["Supporting TITAN screen", f"{n_patients:,}", f"{len(continuous)+len(binary):,}", "TITAN", "Effect threshold plus permutation and within-cancer/family FDR"],
            ["PathoFMPred registry", "Not a new cohort", "Stored fitted-object subset", "Representation-specific", "Research interface; no additional validation evidence"],
        ],
        [3.2, 2.0, 2.6, 3.5, 5.7], font_size=7.2, header_font_size=7.5,
        line_spacing=1.0, fixed_layout=True,
    )
    sup.add_paragraph(
        "The complete family-level eligibility table, candidate counts by cancer and analysis chronology are supplied in the machine-readable companions. The present TCGA benchmark was retrospective and was not prospectively registered."
    )

    sup.add_heading("Table S2. Participant characteristics by cancer", 1)
    sup.add_paragraph(
        "The table provides a compact denominator-first view. The complete file retains missingness, CDR matching and every original category. W/B/A/O denote White, Black or African American, Asian and other recorded race."
    )
    add_table(
        sup,
        ["Cancer", "n", "Age median (IQR)", "Sex F/M", "Race W/B/A/O", "Stage I/II/III/IV"],
        [[r.get("tumor_type"), r.get("patients"),
          f'{fnum(r.get("age_median"),1)} ({fnum(r.get("age_q1"),1)}-{fnum(r.get("age_q3"),1)})',
          f'{r.get("female")}/{r.get("male")}',
          f'{r.get("race_white")}/{r.get("race_black_or_african_american")}/{r.get("race_asian")}/{r.get("race_other_recorded")}',
          f'{r.get("stage_I")}/{r.get("stage_II")}/{r.get("stage_III")}/{r.get("stage_IV")}']
         for r in participant_characteristics],
        [2.1, 1.1, 3.2, 1.8, 3.4, 3.4], font_size=6.6,
        header_font_size=6.9, line_spacing=0.9, fixed_layout=True,
    )
    sup.add_paragraph(
        "Sex- and broad race-stratified performance counts, metrics and reasons for non-estimability are retained in subgroup_performance_audit.csv rather than repeated in the PDF."
    )

    sup.add_heading("Table S3. Slide multiplicity, pathology quality and molecular-slide linkage", 1)
    add_table(
        sup,
        ["Representation", "Released patients", "Released slides", "Common patients", "Multi-slide patients", "Heterogeneity summary"],
        [[display_representation(r.get("foundation_model")), r.get("patients"),
          foundation_cohort_by_model[r.get("foundation_model")]["source_slides"], foundation_common_n,
          r.get("multi_slide_patients"),
          f"median pairwise cosine distance {fnum(r.get('median_pairwise_cosine_distance'),4)}; median max leave-one-out change {fnum(r.get('median_maximum_loo_centroid_distance'),4)}"]
         for r in slide_heterogeneity],
        [2.5, 2.0, 2.0, 2.0, 2.1, 5.0], font_size=7.0,
        header_font_size=7.2, line_spacing=1.0, fixed_layout=True,
    )
    sup.add_paragraph(
        f"No structured tumour cellularity, tissue area, artefact, biopsy/resection or independent slide-quality field was available. Generated narratives flagged {ival(no_residual_patient_summary.get('flagged_patients'))} patients with no-residual-tumour language; these non-adjudicated flags were not used for primary exclusion or weighting."
    )
    add_table(
        sup,
        ["Molecular source", "Identifier resolution", "Covered patients", "Exact sample match", "Multiple primary samples", "Residual limitation"],
        [[r.get("source"), r.get("identifier_resolution"), r.get("covered_patients"),
          (r.get("exact_slide_sample_patients") or "NA"),
          (r.get("patients_with_multiple_molecular_primary_samples") or "NA"),
          r.get("label_noise_note")] for r in molecular_slide_linkage],
        [2.7, 2.4, 1.8, 2.0, 2.4, 5.0], font_size=6.8,
        header_font_size=7.0, line_spacing=1.0, fixed_layout=True,
    )

    sup.add_heading("Table S4. Mutation eligibility and molecular coverage", 1)
    add_table(
        sup,
        ["Documented cancer-gene pairs", "Eligible", "Insufficient positive", "Insufficient negative", "Wild-type rule"],
        [[len(mutation_eligibility), n_mutation_eligible,
          sum(r.get("eligibility") == "insufficient_positive" for r in mutation_eligibility),
          sum(r.get("eligibility") == "insufficient_negative" for r in mutation_eligibility),
          "Assigned only within the MC3-profiled primary-tumour denominator"]],
        [3.2, 1.8, 3.0, 3.0, 5.0], font_size=7.2,
        header_font_size=7.4, line_spacing=1.0, fixed_layout=True,
    )
    sup.add_paragraph("Cancer-specific mutation denominators, multiple aliquots and retained variant classes are supplied in mutation_coverage_audit.csv, mutation_target_eligibility_audit.csv and mutation_variant_classification_audit.csv.")

    sup.add_heading("Table S5. Non-mutation outcome-source coverage", 1)
    add_table(
        sup,
        ["Source", "Cohort", "N covered", "N missing", "N multi-primary", "Max aliquots", "Aggregation rule"],
        source_coverage_summary,
        [2.5, 1.3, 1.6, 1.6, 2.2, 1.8, 4.2], font_size=7.0,
        header_font_size=7.2, line_spacing=1.0, fixed_layout=True,
    )

    sup.add_heading("Table S6. Highlighted TITAN-model performance and conditional uncertainty", 1)
    sup.add_paragraph(
        "Initial-screen estimates and five-repeat means are labelled separately. SC intervals resample patients from five fixed repeated out-of-fold prediction sets and do not repeat screening, partition generation, tuning or fitting. They are not external-generalisation intervals."
    )
    highlighted_rows = []
    for r in highlighted:
        if r.get("outcome_type") == "binary":
            primary = f"BA {fnum(r.get('primary_screen_balanced_accuracy'))}"
            repeated = f"BA {fnum(r.get('balanced_accuracy'))}; AUROC {fnum(r.get('auc'))}; PR-AUC {fnum(r.get('pr_auc'))}"
            interval = f"BA {fnum(r.get('balanced_accuracy_ci_low'))}-{fnum(r.get('balanced_accuracy_ci_high'))}"
        else:
            primary = f"Q2 {fnum(r.get('primary_screen_q2'))}"
            repeated = f"Q2 {fnum(r.get('q2'))}; RMSE {fnum(r.get('rmse'))}; rho {fnum(r.get('spearman'))}"
            interval = f"Q2 {fnum(r.get('q2_ci_low'))}-{fnum(r.get('q2_ci_high'))}"
        highlighted_rows.append([
            r.get("outcome_type"), f"{r.get('tumor_type')}-{r.get('endpoint')}", r.get("n"),
            primary, repeated, interval,
            f"{r.get('site_grouped_metric_name')} {fnum(r.get('site_grouped_metric'))}; {r.get('site_robustness_status')}",
        ])
    add_table(
        sup,
        ["Type", "Cancer-endpoint", "n", "Initial", "Five-repeat mean", "95% SC interval", "Grouped by tissue-source-site code"],
        highlighted_rows,
        [1.6, 3.8, 1.0, 1.8, 4.2, 2.2, 4.0], font_size=6.4,
        header_font_size=6.7, line_spacing=0.9, fixed_layout=True,
    )
    sup.add_paragraph("Complete sensitivity, specificity, PPV, NPV, fold distributions, metadata, checksums and access fields remain in highlighted_model_performance.csv and models/model_registry.csv.")

    sup.add_heading("Table S7. Ten strongest continuous results in the supporting TITAN screen", 1)
    add_table(sup, ["Cancer", "Endpoint", "Family", "n", "Primary Q2", "q"],
              [[r["tumor_type"], r["endpoint"], r["family"], r["n"], fnum(r["q2"]), fnum(r["q_value"])] for r in top_c[:10]],
              [1.8, 4.5, 3.0, 1.2, 2.0, 2.0], font_size=7.0, header_font_size=7.2, line_spacing=1.0, fixed_layout=True)
    sup.add_paragraph("continuous_screen.csv and continuous_repeated_nested_cv.csv retain all eligible and repeated records.")

    sup.add_heading("Table S8. Ten strongest binary results in the supporting TITAN screen", 1)
    add_table(sup, ["Cancer", "Endpoint", "Family", "n", "Positive", "Primary BA", "Repeated PR-AUC", "q"],
              [[r["tumor_type"], r["endpoint"], r["family"], r["n"], r["positive"], fnum(r["balanced_accuracy"]),
                fnum(binary_reliability_by_key.get((r["family"], r["tumor_type"], r["endpoint"]), {}).get("repeated_pr_auc_mean")), fnum(r["q_value"])] for r in top_b[:10]],
              [1.5, 3.1, 2.4, 1.0, 1.2, 1.7, 2.0, 1.6], font_size=6.7, header_font_size=6.9, line_spacing=0.9, fixed_layout=True)
    sup.add_paragraph("binary_screen.csv and binary_repeated_nested_cv.csv retain all eligible and repeated records.")

    sup.add_heading("Table S9. Targeted mutation-prediction literature audit", 1)
    add_table(sup, ["Evidence class", "Cancer-gene pairs", "Interpretation"],
              [[cls, count, "Targeted narrative cross-check; not a systematic-review novelty claim"]
               for cls, count in sorted(Counter(r["evidence_class"] for r in mutation_literature_audit).items())],
              [6.0, 2.5, 7.0], font_size=7.1, header_font_size=7.3, line_spacing=1.0, fixed_layout=True)
    sup.add_paragraph("supported_mutation_literature_audit.csv and prior_mutation_accuracy_comparison.csv retain every mapping, metric, source and colorectal-scope decision.")

    sup.add_heading("Table S10. Statistical and robustness audit summary", 1)
    add_table(
        sup,
        ["Audit", "Scope", "Principal result", "Complete companion"],
        [
            ["Permutation and multiplicity", "2,073 eligible TITAN tasks", f"{ival(combined_multiplicity.get('atlas_wide_pass'))}/{ival(combined_multiplicity.get('eligible_tests'))} passed the single atlas-wide BH sensitivity", "multiplicity_denominator_audit.csv"],
            ["Tissue-source-site-code grouping", f"{titan_candidate_total} TITAN candidates", f"{ival(site_combined.get('below_threshold_models'))} fell below the original effect threshold", "site_grouped_models_below_effect_threshold.csv"],
            ["Binary class size", f"{len(supported_b)} TITAN candidates", f"{len(binary_limited_reliability)} had fewer than 50 patients in one class", "binary_class_reliability_summary.csv"],
            ["Continuous sample size", f"{len(continuous_reliability)} TITAN candidates", f"{len(continuous_limited_reliability)} had fewer than 100 labelled patients", "continuous_reliability_by_model.csv"],
            ["PLS versus ridge", f"{len(ridge_comparison)} metadata-selected targets", f"Ridge favoured {len(ridge_better)}, PLS favoured {len(pls_better)}, uncertain {len(baseline_uncertain)}", "pls_vs_ridge_representative_models.csv"],
            ["Median versus mean pooling", f"{sum(ival(r.get('models')) for r in median_pool_summary)} TITAN models", "Small median changes with outcome-specific rank concordance reported", "median_pooling_sensitivity_summary.csv"],
        ],
        [3.2, 3.0, 6.2, 4.2], font_size=7.0, header_font_size=7.2,
        line_spacing=1.0, fixed_layout=True,
    )
    sup.add_heading("Table S10j. AUROC-centred binary benchmark and operating-rule sensitivity", 2)
    add_table(
        sup,
        ["Representation", "Tasks", "AUROC crossings", "Median AUROC", "Median PR-AUC", "Training-threshold BA crossings", "Ceiling fits"],
        [[display_representation(m), r["tasks"], r["auroc_tuned_auroc_crossings"],
          fnum(binary_operating_value(m, "training-only optimized threshold", "median_auroc"),3),
          fnum(binary_operating_value(m, "training-only optimized threshold", "median_pr_auc"),3),
          binary_operating_value(m, "training-only optimized threshold", "ba_crossings_for_sensitivity"),
          f"{r['component_ceiling_outer_fits']}/2,130"]
         for m in ("TITAN", "GigaSSL", "ProvGigaPath") for r in [foundation_binary_auroc_by_model[m]]],
        [2.6, 1.3, 2.3, 2.0, 2.0, 3.0, 2.0], font_size=7.0,
        header_font_size=7.2, line_spacing=1.0, fixed_layout=True,
    )
    sup.add_paragraph("The complete empirical-prior, equal-prior and training-threshold operating metrics and fold-level thresholds are machine readable. AUROC and PR-AUC are unchanged by the final class-call rule on a fixed selected score.")

    sup.add_heading("Table S11. Prior pan-cancer histology-prediction landscape", 1)
    add_table(sup, ["Study", "Year", "Scope", "Endpoints", "External validation", "Reported performance"],
              [[r.get("study"), r.get("year"), r.get("scope"), r.get("endpoints"), r.get("external_validation"), r.get("reported_performance")] for r in literature_landscape],
              [2.7, 1.0, 3.5, 3.8, 2.6, 3.4], font_size=6.6, header_font_size=6.9, line_spacing=0.9, fixed_layout=True)

    sup.add_heading("Table S12. TRIPOD+AI reporting map", 1)
    sup.add_paragraph("This complete reporting map uses the official TRIPOD+AI checklist. Pending entries require author or institutional information.")
    add_table(sup, ["Item", "Topic", "Reported location", "Status"],
              [[r.get("item"), r.get("topic"),
                (r.get("reported_location") or "").replace("PLS1 regression", "single-outcome PLS regression").replace("PLS2", "multi-outcome PLS"),
                r.get("status")] for r in tripod_map],
              [1.3, 5.0, 6.5, 3.5], font_size=6.6, header_font_size=6.9, line_spacing=0.9, fixed_layout=True)

    sup.add_heading("Table S13. Endpoint provenance, derivation and assay equivalence", 1)
    add_table(sup, ["Measurement class", "Cancer-endpoint tests", "Unique definitions", "Same-H&E tests"],
              endpoint_class_summary, [8.0, 3.0, 3.0, 3.0], font_size=7.0, header_font_size=7.2, line_spacing=1.0, fixed_layout=True)
    add_table(sup, ["Source", "Label domains", "Identifier", "Processing and participant rule"],
              [[r["source"], r["label_domains"], r["source_identifier"], r["input_processing"] + "; " + r["participant_aggregation"] + "; " + r["missing_or_negative_rule"]] for r in outcome_source_acquisition],
              [2.7, 4.2, 2.7, 7.4], font_size=6.5, header_font_size=6.8, line_spacing=0.9, fixed_layout=True)
    sup.add_paragraph("endpoint_dictionary.csv is the complete 2,073-row target dictionary and includes modality, direct/inferred status, algorithm, scale, transformation, missingness, expected error, interpretation and assay-equivalence caveat.")

    sup.add_heading("Table S14. Qualitative morphology-context examples", 1)
    add_table(sup, ["Cancer-endpoint", "Reference class", "High patient", "Low patient", "Interpretation"],
              [[f'{r.get("tumor_type")}-{r.get("endpoint")}', r.get("context_class"), r.get("high_anchor"), r.get("low_anchor"), r.get("interpretation")] for r in morphology_context_summary],
              [4.2, 3.7, 2.8, 2.8, 4.5], font_size=6.8, header_font_size=7.0, line_spacing=1.0, fixed_layout=True)
    sup.add_paragraph("These nearest-neighbour examples are qualitative context, not spatial attribution or blinded pathology validation. Full patient, slide, prediction and cosine-similarity records remain in morphology_context_examples.csv.")

    sup.add_heading("Table S15. Matched three-representation benchmark", 1)
    add_table(sup, ["Representation", "Released slides", "Released patients", "Matched patients", "Dimensions", "Continuous crossings", "Binary crossings"],
              [[display_representation(m), foundation_cohort_by_model[m]["source_slides"], foundation_cohort_by_model[m]["patients"], foundation_common_n,
                foundation_cohort_by_model[m]["dimensions"], foundation_crossings(m,"continuous"), foundation_crossings(m,"binary")]
               for m in ("TITAN", "GigaSSL", "ProvGigaPath")],
              [2.7, 2.0, 2.1, 2.0, 1.6, 2.7, 2.4], font_size=7.0, header_font_size=7.2, line_spacing=1.0, fixed_layout=True)
    sup.add_paragraph("Crossings use Q2 at least 0.20 or AUROC at least 0.60. They are descriptive and are not representation-specific permutation/FDR discoveries.")
    sup.add_heading("Table S15a. Component-ceiling audit", 2)
    add_table(sup, ["Representation", "Outcome", "Targets", "Median components", "Targets with any ceiling", "Outer fits at ceiling"],
              [[display_representation(r["foundation_model"]), r["outcome_type"], r["targets"], fnum(r["selected_components_median"],1), r["targets_with_any_outer_fit_at_ceiling"], f"{r.get('outer_fits_at_ceiling')}/{r.get('outer_fits_total')}"] for r in foundation_component_audit],
              [2.7, 2.0, 1.5, 2.5, 3.3, 3.0], font_size=7.0, header_font_size=7.2, line_spacing=1.0, fixed_layout=True)
    sup.add_heading("Table S15e. Representation pipelines not included", 2)
    add_table(sup, ["Model or family", "Representation level", "Reason not included", "Criterion not met"],
              [[r["model_or_family"], r["representation_level"], r["reason_not_included"], r["criterion_not_met"]] for r in foundation_exclusion_inventory],
              [3.0, 2.7, 7.0, 4.2], font_size=6.7, header_font_size=6.9, line_spacing=0.9, fixed_layout=True)
    sup.add_paragraph("Complete pairwise effects, alternative partitions, threshold curves, grouped-fold adequacy, ridge sensitivity and the 1-20-component audit remain in the foundation_model_* companion files.")

    sup.add_heading("Table S16. Exact slide-set intersection sensitivity", 1)
    sup.add_paragraph(f"Within the matched cohort, exact slide sets agreed for {ival(foundation_slide_audit.get('identical_slide_set_patients')):,}/{foundation_common_n:,} patients. The exact three-way intersection contained {ival(foundation_slide_audit.get('exact_common_slides')):,} slides and retained every patient.")
    add_table(sup, ["Representation", "Outcome", "Tasks", "Primary crossings", "Exact-slide crossings", "Lost/gained", "Median change", "Spearman"],
              [[display_representation(r["foundation_model"]), r["outcome_type"], r["tasks"], r["primary_screening_positive"], r["exact_screening_positive"], f"{r['lost_threshold']}/{r['gained_threshold']}", fnum(r["median_delta"],4), fnum(r["spearman_primary_exact"],3)] for r in foundation_exact_slide_sensitivity],
              [2.4, 1.7, 1.2, 2.2, 2.4, 1.8, 2.2, 2.0], font_size=6.8, header_font_size=7.0, line_spacing=0.9, fixed_layout=True)

    sup.add_heading("Table S17. Catalogue-normalized representation breadth", 1)
    add_table(sup, ["Representation", "Outcome", "Task crossings", "Unique definitions", "Macro family %", "Macro cancer %", "Largest family share"],
              [[display_representation(r["foundation_model"]), r["outcome_type"], f"{r['task_crossings']}/{r['eligible_tasks']} ({fnum(r['task_crossing_percent'],1)}%)",
                f"{r['endpoint_definitions_crossing']}/{r['eligible_endpoint_definitions']} ({fnum(r['endpoint_definition_crossing_percent'],1)}%)",
                fnum(r["macro_family_crossing_percent"],1), fnum(r["macro_cancer_crossing_percent"],1),
                f"{r['largest_crossing_family']}: {fnum(r['largest_family_share_of_crossings'],1)}%"]
               for r in sorted(foundation_normalized_breadth, key=lambda x:(x["foundation_model"],x["outcome_type"]))],
              [2.5, 1.6, 3.0, 3.1, 2.0, 2.0, 3.0], font_size=6.8, header_font_size=7.0, line_spacing=0.9, fixed_layout=True)
    sup.add_paragraph("Complete family, cancer, endpoint-definition and biological-programme retention tables remain in the normalized-breadth companion files. Counts describe catalogue breadth, not independent biological discoveries.")

    sup.add_heading("Table S18. Endpoint-provenance stratification and same-H&E sensitivity", 1)
    add_table(sup, ["Representation", "Outcome", "Measurement class", "Eligible", "Crossings", "Crossing %"],
              [[display_representation(r["foundation_model"]), r["outcome_type"], r["measurement_class"], r["eligible_tasks"], r["effect_threshold_crossings"], fnum(r["crossing_percent"],1)]
               for r in sorted(foundation_provenance_summary, key=lambda x:(x["outcome_type"],x["measurement_class"],x["foundation_model"]))],
              [2.3, 1.5, 5.0, 1.5, 1.7, 1.8], font_size=6.6, header_font_size=6.9, line_spacing=0.9, fixed_layout=True)
    add_table(sup, ["Representation", "Continuous all", "Continuous excluding same-H&E", "All matched excluding same-H&E"],
              [[display_representation(r["foundation_model"]), f"{r['all_continuous_crossings']}/{r['all_continuous_tasks']}", f"{r['cross_modal_continuous_crossings']}/{r['cross_modal_continuous_tasks']}", f"{r['matched_crossings_excluding_same_histology']}/{r['matched_tasks_excluding_same_histology']}"]
               for r in sorted(foundation_same_histology, key=lambda x:x["foundation_model"])],
              [2.8, 3.2, 5.0, 5.0], font_size=7.0, header_font_size=7.2, line_spacing=1.0, fixed_layout=True)
    sup.add_paragraph("CIBERSORT fractions, methylation-derived leukocyte estimates and RNA signatures measure agreement with computational reference phenotypes. The H&E-derived TIL fraction is same-modality concordance and is excluded from the default cross-modal continuous summary.")


def _compact_supp_tables_revised():
    """Short, three-representation Supplement with sequential table numbering."""

    def target(tumour, endpoint):
        return next(
            (r for r in foundation_target_comparison
             if r.get("tumor_type") == tumour and r.get("endpoint") == endpoint),
            None,
        )

    def family(model, outcome, family_name):
        return next(
            (r for r in foundation_family_summary
             if r.get("foundation_model") == model
             and r.get("outcome_type") == outcome
             and r.get("family") == family_name),
            None,
        )

    def crossing_cell(record):
        if not record:
            return "NA"
        return (
            f"{ival(record.get('effect_threshold_crossings'))}/"
            f"{ival(record.get('eligible_tasks'))} "
            f"({fnum(record.get('crossing_percent'), 1)}%)"
        )

    add_table(
        sup,
        ["Layer", "Patients", "Cancer-endpoint tasks", "Representations", "Qualification"],
        [
            ["Matched benchmark", f"{foundation_common_n:,}", "3,389", "TITAN, Giga-SSL, Prov-GigaPath", "Descriptive Q2/AUROC comparison on matched patients and folds"],
            ["Supporting TITAN screen", f"{n_patients:,}", f"{len(continuous)+len(binary):,}", "TITAN", "Effect threshold plus permutation and within-cancer/family FDR"],
            ["PathoFMPred registry", "Not a new cohort", "Stored fitted-object subset", "Representation-specific", "Research interface; no additional validation evidence"],
        ],
        [3.2, 2.0, 2.6, 3.5, 5.7], font_size=7.2, header_font_size=7.5,
        line_spacing=1.0, fixed_layout=True,
    )
    sup.add_paragraph(
        "The complete family-level eligibility table, candidate counts by cancer and analysis chronology are supplied in machine-readable companions. The TCGA benchmark was retrospective and was not prospectively registered."
    )

    sup.add_heading("Table S2. Participant characteristics of the full TITAN cohort by cancer", 1)
    sup.add_paragraph(
        "This table describes the 9,404-patient TITAN cohort used for the supporting permutation/FDR screen, not the 8,241-patient matched comparison. The complete file retains missingness, CDR matching and every original category. W/B/A/O denote White, Black or African American, Asian and other recorded race."
    )
    add_table(
        sup,
        ["Cancer", "n", "Age median (IQR)", "Sex F/M", "Race W/B/A/O", "Stage I/II/III/IV"],
        [[r.get("tumor_type"), r.get("patients"),
          f'{fnum(r.get("age_median"),1)} ({fnum(r.get("age_q1"),1)}-{fnum(r.get("age_q3"),1)})',
          f'{r.get("female")}/{r.get("male")}',
          f'{r.get("race_white")}/{r.get("race_black_or_african_american")}/{r.get("race_asian")}/{r.get("race_other_recorded")}',
          f'{r.get("stage_I")}/{r.get("stage_II")}/{r.get("stage_III")}/{r.get("stage_IV")}']
         for r in participant_characteristics],
        [2.1, 1.1, 3.2, 1.8, 3.4, 3.4], font_size=6.6,
        header_font_size=6.9, line_spacing=0.9, fixed_layout=True,
    )
    sup.add_paragraph(
        "Sex- and broad race-stratified performance counts, metrics and reasons for non-estimability remain in subgroup_performance_audit.csv."
    )

    sup.add_heading("Table S3. Slide multiplicity, pathology quality and molecular-slide linkage", 1)
    add_table(
        sup,
        ["Representation", "Released patients", "Released slides", "Common patients", "Multi-slide patients", "Heterogeneity summary"],
        [[display_representation(r.get("foundation_model")), r.get("patients"),
          foundation_cohort_by_model[r.get("foundation_model")]["source_slides"], foundation_common_n,
          r.get("multi_slide_patients"),
          f"median pairwise cosine distance {fnum(r.get('median_pairwise_cosine_distance'),4)}; median max leave-one-out change {fnum(r.get('median_maximum_loo_centroid_distance'),4)}"]
         for r in slide_heterogeneity],
        [2.5, 2.0, 2.0, 2.0, 2.1, 5.0], font_size=7.0,
        header_font_size=7.2, line_spacing=1.0, fixed_layout=True,
    )
    sup.add_paragraph(
        f"No structured tumour cellularity, tissue area, artefact, biopsy/resection or independent slide-quality field was available. Generated narratives flagged {ival(no_residual_patient_summary.get('flagged_patients'))} patients with no-residual-tumour language; these non-adjudicated flags were not used for primary exclusion or weighting."
    )
    add_table(
        sup,
        ["Molecular source", "Identifier resolution", "Covered patients", "Exact sample match", "Multiple primary samples", "Residual limitation"],
        [[r.get("source"), r.get("identifier_resolution"), r.get("covered_patients"),
          (r.get("exact_slide_sample_patients") or "NA"),
          (r.get("patients_with_multiple_molecular_primary_samples") or "NA"),
          r.get("label_noise_note")] for r in molecular_slide_linkage],
        [2.7, 2.4, 1.8, 2.0, 2.4, 5.0], font_size=6.8,
        header_font_size=7.0, line_spacing=1.0, fixed_layout=True,
    )
    sup.add_paragraph(
        f"Mutation eligibility was documented for {len(mutation_eligibility)} cancer-gene pairs. Of these, {n_mutation_eligible} met the analysis denominator; the remaining pairs lacked sufficient positive or negative cases. Wild type was assigned only inside the MC3-profiled primary-tumour denominator. Cancer-specific coverage, aliquot handling and retained variant classes remain in mutation_coverage_audit.csv, mutation_target_eligibility_audit.csv and mutation_variant_classification_audit.csv."
    )

    sup.add_paragraph(
        "The outcome-acquisition Methods above report the source, identifier, participant-level aggregation, "
        "negative assignment and transformation for the Thorsson, Gao, Sanchez-Vega, Taylor and cBioPortal "
        "resources. Complete source-specific coverage, missingness and aliquot counts remain in "
        "molecular_source_coverage_audit.csv and outcome_source_acquisition_map.csv."
    )

    binary_specs = [
        ("Mutation", "THYM", "GTF2I"),
        ("Mutation", "THCA", "BRAF"),
        ("Mutation", "LGG", "IDH1"),
        ("Mutation", "LGG", "TP53"),
        ("Mutation", "BLCA", "FGFR3"),
        ("Fusion", "UCEC", "Any called fusion"),
        ("Fusion", "THCA", "Fusion pair: CCDC6--RET"),
        ("Fusion", "PRAD", "Fusion pair: TMPRSS2--ERG"),
        ("MSI", "COAD", "MSI-H strict (MANTIS >0.6)"),
        ("Genome doubling", "UCEC", "Genome doubling"),
        ("Oncogenic pathway", "KIRP", "Cell Cycle"),
    ]
    binary_rows = []
    for feature_class, tumour, endpoint in binary_specs:
        r = target(tumour, endpoint)
        if not r:
            continue
        binary_rows.append([
            feature_class,
            f"{tumour}: {endpoint.replace('Fusion pair: ', '')}",
            f"{ival(r.get('n'))} ({ival(r.get('positive'))} positive)",
            fnum(r.get("auc_TITAN"), 3),
            fnum(r.get("auc_GigaSSL"), 3),
            fnum(r.get("auc_ProvGigaPath"), 3),
            r.get("support_pattern"),
        ])
    sup.add_heading("Table S4. Selected binary tumour-feature predictions across all three representation pipelines", 1)
    sup.add_paragraph(
        "Values are patient-level outer out-of-fold AUROCs in the matched cohort. The examples span mutations, gene fusions, MSI, genome doubling and oncogenic pathways. Support states which pipelines crossed AUROC 0.60; it is a descriptive navigation field, not a multiplicity-controlled discovery label."
    )
    add_table(
        sup,
        ["Feature class", "Cancer and endpoint", "n (positive)", "TITAN AUROC", "Giga-SSL AUROC", "Prov-GigaPath AUROC", "Pipelines crossing 0.60"],
        binary_rows,
        [2.3, 4.0, 2.2, 2.0, 2.2, 2.4, 3.7], font_size=6.7,
        header_font_size=6.9, line_spacing=0.9, fixed_layout=True,
    )
    sup.add_paragraph(
        "Fusion findings were substantive. Across 26 eligible binary fusion tasks, TITAN crossed for 12, Giga-SSL for 11 and Prov-GigaPath for 10. UCEC, LGG, THCA and BLCA any-fusion status and PRAD TMPRSS2-ERG crossed with all three pipelines. Complete sensitivity, specificity, PR-AUC, PPV, NPV, prevalence and fold-level results remain in foundation_model_target_comparison.csv and foundation_model_matched_screen.csv."
    )

    continuous_specs = [
        ("RNA pathway activity", "TGCT", "HALLMARK_GLYCOLYSIS"),
        ("RNA pathway activity", "LIHC", "HALLMARK_BILE_ACID_METABOLISM"),
        ("RNA pathway activity", "PAAD", "HALLMARK_NOTCH_SIGNALING"),
        ("RNA inflammatory signature", "TGCT", "TGF-beta Response"),
        ("Inferred immune fraction", "THYM", "Th17 Cells"),
        ("Methylation-derived fraction", "BLCA", "Leukocyte Fraction"),
        ("Methylation-derived fraction", "KIRP", "Leukocyte Fraction"),
        ("Immune repertoire", "THYM", "TCR Shannon"),
        ("Composite tissue context", "TGCT", "Stromal Fraction"),
        ("RNA inflammatory signature", "THCA", "Lymphocyte Infiltration Signature Score"),
        ("Fusion burden", "UCEC", "Fusion burden"),
        ("Fusion burden", "LGG", "Fusion burden"),
        ("Aneuploidy", "UCEC", "Aneuploidy score"),
    ]
    continuous_rows = []
    for feature_class, tumour, endpoint in continuous_specs:
        r = target(tumour, endpoint)
        if not r:
            continue
        continuous_rows.append([
            feature_class,
            f"{tumour}: {endpoint}",
            ival(r.get("n")),
            fnum(r.get("q2_TITAN"), 3),
            fnum(r.get("q2_GigaSSL"), 3),
            fnum(r.get("q2_ProvGigaPath"), 3),
            r.get("support_pattern"),
        ])
    sup.add_heading("Table S5. Selected continuous tumour-feature predictions across all three representation pipelines", 1)
    sup.add_paragraph(
        "Values are patient-level outer out-of-fold Q² estimates in the matched cohort. Immune-cell fractions and expression signatures are computational reference phenotypes rather than directly measured cell counts. Support states which pipelines crossed Q² 0.20."
    )
    add_table(
        sup,
        ["Feature class", "Cancer and endpoint", "n", "TITAN Q2", "Giga-SSL Q2", "Prov-GigaPath Q2", "Pipelines crossing 0.20"],
        continuous_rows,
        [3.0, 4.2, 1.2, 1.8, 2.0, 2.3, 3.7], font_size=6.7,
        header_font_size=6.9, line_spacing=0.9, fixed_layout=True,
    )
    sup.add_paragraph(
        "Continuous fusion burden crossed only with TITAN in UCEC and LGG. This contrasts with the broader binary any-fusion results and shows that detecting the presence of a called fusion is not equivalent to predicting the number of fusion calls."
    )

    family_specs = [
        ("Binary", "Driver mutations", "binary", "driver_mutation"),
        ("Binary", "Fusion status and recurrent fusion pairs", "binary", "fusion"),
        ("Binary", "Genome doubling", "binary", "aneuploidy"),
        ("Binary", "MSI-H", "binary", "microsatellite_instability"),
        ("Binary", "Strict MSI-H sensitivity", "binary", "microsatellite_instability_sensitivity"),
        ("Binary", "Oncogenic-pathway status", "binary", "oncogenic_pathway"),
        ("Continuous", "Thorsson immune, inflammatory and context features", "continuous", "thorsson"),
        ("Continuous", "Aneuploidy burdens", "continuous", "aneuploidy"),
        ("Continuous", "Fusion burden", "continuous", "fusion"),
        ("Continuous", "MSI scores", "continuous", "microsatellite_instability"),
        ("Continuous", "RNA-derived pathway activities", "continuous", "rna_pathway_activity"),
    ]
    family_rows = []
    for outcome_label, display_name, outcome, family_name in family_specs:
        t = family("TITAN", outcome, family_name)
        g = family("GigaSSL", outcome, family_name)
        p = family("ProvGigaPath", outcome, family_name)
        family_rows.append([
            outcome_label,
            display_name,
            ival((t or g or p or {}).get("eligible_tasks")),
            crossing_cell(t), crossing_cell(g), crossing_cell(p),
        ])
    sup.add_heading("Table S6. Feature-family predictability across all three representation pipelines", 1)
    sup.add_paragraph(
        "Each cell reports effect-threshold crossings divided by eligible cancer-endpoint pairs. Binary crossings use AUROC at least 0.60 and continuous crossings use Q² at least 0.20. Counts measure task-level breadth within this catalogue, not independent biological discoveries."
    )
    add_table(
        sup,
        ["Outcome", "Tumour-feature family", "Eligible tasks", "TITAN", "Giga-SSL", "Prov-GigaPath"],
        family_rows,
        [1.7, 5.4, 1.8, 2.8, 2.8, 3.1], font_size=6.8,
        header_font_size=7.0, line_spacing=0.9, fixed_layout=True,
    )

    sup.add_heading("Table S7. Literature context and contribution by tumour-feature class", 1)
    add_table(
        sup,
        ["Feature class", "Representative prior H&E evidence", "What the present atlas contributes"],
        [
            ["Driver mutations", "Coudray et al.; Fu et al.; Kather et al.; Loeffler et al.; Saldanha et al.; Arslan et al. [1,4,5,8,11,13]", "Matched patient-level comparison of three released representation pipelines, negative and ineligible records, and cancer-specific reusable linear heads."],
            ["Gene fusions", "ERG rearrangement in prostate cancer and ALK/ROS1 fusions in lung cancer were predicted previously, including external testing [9,10].", "Compares any-fusion and eligible recurrent-pair tasks across cancers and representations; identifies UCEC any-fusion as the strongest shared result and separates fusion status from continuous fusion burden."],
            ["MSI", "CRC, gastric and UCEC MSI models have strong precedent, including independent cohorts [2,3,5].", "Applies common broad and strict MANTIS definitions across the matched pipelines and reports PR-AUC, prevalence and cohort-structure sensitivity."],
            ["Aneuploidy and genome doubling", "Fu et al. linked H&E features to whole-genome duplication and chromosomal aneuploidies [4].", "Evaluates Taylor arm-level burdens and genome doubling with the same patient-level probe across all three representation pipelines."],
            ["Oncogenic pathways", "Loeffler et al. compared gene and pathway alterations; HE2RNA linked histology to transcriptomic pathways [6,8].", "Screens the same ten Sanchez-Vega pathway states across eligible cancers and all three representations."],
            ["Immune and inflammatory phenotypes", "Fu et al., HE2RNA, regression-based biomarker modelling and HistoTME predicted tumour composition, expression or microenvironment phenotypes [4,6,12,15].", "Evaluates one documented panel of inferred fractions, RNA signatures, repertoire measures and composite tissue-context scores across 32 cancers while preserving their reference-label provenance."],
            ["Broad multi-omic screening", "Arslan et al. trained 12,093 models for 4,031 biomarkers across the same 32 TCGA cancers [13].", "Adds a matched three-representation comparison, deterministic patient-level slide pooling, explicit tested-negative outputs and representation-specific linear model records."],
        ],
        [3.2, 6.8, 7.0], font_size=6.8, header_font_size=7.0,
        line_spacing=0.95, fixed_layout=True,
    )
    sup.add_paragraph(
        "The literature establishes precedent for every broad feature class. The contribution of this study lies primarily in the common three-pipeline, patient-level atlas and its reusable model records. Some exact cancer-feature combinations, including UCEC and LGG fusion burden, appear less commonly studied, but we do not claim endpoint novelty without a dedicated systematic review."
    )

    sup.add_heading("Table S8. Statistical and robustness audit summary", 1)
    add_table(
        sup,
        ["Audit", "Scope", "Principal result", "Complete companion"],
        [
            ["Permutation and multiplicity", "3,633 eligible TITAN tasks", f"{ival(combined_multiplicity.get('atlas_wide_pass'))}/{ival(combined_multiplicity.get('eligible_tests'))} passed the single atlas-wide BH sensitivity", "multiplicity_denominator_audit.csv"],
            ["Tissue-source-site-code grouping", f"{titan_candidate_total} TITAN candidates", f"{ival(site_combined.get('below_threshold_models'))} fell below the original effect threshold", "site_grouped_models_below_effect_threshold.csv"],
            ["Binary class size", f"{len(supported_b)} TITAN candidates", f"{len(binary_limited_reliability)} had fewer than 50 patients in one class", "binary_class_reliability_summary.csv"],
            ["Continuous sample size", f"{len(continuous_reliability)} TITAN candidates", f"{len(continuous_limited_reliability)} had fewer than 100 labelled patients", "continuous_reliability_by_model.csv"],
            ["PLS versus ridge", f"{len(ridge_comparison)} metadata-selected targets", f"Ridge favoured {len(ridge_better)}, PLS favoured {len(pls_better)}, uncertain {len(baseline_uncertain)}", "pls_vs_ridge_representative_models.csv"],
            ["Median versus mean pooling", f"{sum(ival(r.get('models')) for r in median_pool_summary)} TITAN models", "Small median changes with outcome-specific rank concordance reported", "median_pooling_sensitivity_summary.csv"],
        ],
        [3.2, 3.0, 6.2, 4.2], font_size=7.0, header_font_size=7.2,
        line_spacing=1.0, fixed_layout=True,
    )
    operating_text = "; ".join(
        f"{display_representation(m)}: {r['auroc_tuned_auroc_crossings']} AUROC crossings, median AUROC {fnum(binary_operating_value(m, 'training-only optimized threshold', 'median_auroc'),3)} and median PR-AUC {fnum(binary_operating_value(m, 'training-only optimized threshold', 'median_pr_auc'),3)}"
        for m in ("TITAN", "GigaSSL", "ProvGigaPath")
        for r in [foundation_binary_auroc_by_model[m]]
    )
    sup.add_paragraph(
        "The AUROC-centred binary and operating-rule sensitivity is summarised in text rather than a separate small table. "
        + operating_text
        + ". Complete empirical-prior, equal-prior, training-threshold and fold-level threshold records remain machine readable."
    )

    sup.add_heading("Table S9. Endpoint provenance, derivation and assay equivalence", 1)
    add_table(
        sup,
        ["Measurement class", "Cancer-endpoint tests", "Unique definitions", "Same-H&E tests"],
        endpoint_class_summary, [8.0, 3.0, 3.0, 3.0], font_size=7.0,
        header_font_size=7.2, line_spacing=1.0, fixed_layout=True,
    )
    add_table(
        sup,
        ["Source", "Label domains", "Identifier", "Processing and participant rule"],
        [[r["source"], r["label_domains"], r["source_identifier"], r["input_processing"] + "; " + r["participant_aggregation"] + "; " + r["missing_or_negative_rule"]] for r in outcome_source_acquisition],
        [2.7, 4.2, 2.7, 7.4], font_size=6.5, header_font_size=6.8,
        line_spacing=0.9, fixed_layout=True,
    )
    sup.add_paragraph(
        "endpoint_dictionary.csv supplies the complete target-level dictionary, including modality, direct or inferred status, derivation algorithm, scale, transformation, missingness, expected error, interpretation and assay-equivalence caveat."
    )

    sup.add_heading("Table S10. Matched three-representation benchmark", 1)
    add_table(
        sup,
        ["Representation", "Released slides", "Released patients", "Matched patients", "Dimensions", "Continuous crossings", "Binary crossings"],
        [[display_representation(m), foundation_cohort_by_model[m]["source_slides"], foundation_cohort_by_model[m]["patients"], foundation_common_n,
          foundation_cohort_by_model[m]["dimensions"], foundation_crossings(m,"continuous"), foundation_crossings(m,"binary")]
         for m in ("TITAN", "GigaSSL", "ProvGigaPath")],
        [2.7, 2.0, 2.1, 2.0, 1.6, 2.7, 2.4], font_size=7.0,
        header_font_size=7.2, line_spacing=1.0, fixed_layout=True,
    )
    sup.add_paragraph(
        "Crossings use Q² at least 0.20 or AUROC at least 0.60. They are descriptive and are not representation-specific permutation/FDR discoveries."
    )
    sup.add_heading("Table S10a. Component-ceiling audit", 2)
    add_table(
        sup,
        ["Representation", "Outcome", "Targets", "Median components", "Targets with any ceiling", "Outer fits at ceiling"],
        [[display_representation(r["foundation_model"]), r["outcome_type"], r["targets"], fnum(r["selected_components_median"],1), r["targets_with_any_outer_fit_at_ceiling"], f"{r.get('outer_fits_at_ceiling')}/{r.get('outer_fits_total')}"] for r in foundation_component_audit],
        [2.7, 2.0, 1.5, 2.5, 3.3, 3.0], font_size=7.0,
        header_font_size=7.2, line_spacing=1.0, fixed_layout=True,
    )
    sup.add_heading("Table S10b. Representation pipelines not included", 2)
    add_table(
        sup,
        ["Model or family", "Representation level", "Reason not included", "Criterion not met"],
        [[r["model_or_family"], r["representation_level"], r["reason_not_included"], r["criterion_not_met"]] for r in foundation_exclusion_inventory],
        [3.0, 2.7, 7.0, 4.2], font_size=6.7, header_font_size=6.9,
        line_spacing=0.9, fixed_layout=True,
    )
    sup.add_paragraph(
        "Complete pairwise effects, alternative partitions, threshold curves, grouped-fold adequacy, ridge sensitivity and the 1-20-component audit remain in the foundation_model_* companion files."
    )

    sup.add_heading("Table S11. Exact slide-set intersection sensitivity", 1)
    sup.add_paragraph(
        f"Within the matched cohort, exact slide sets agreed for {ival(foundation_slide_audit.get('identical_slide_set_patients')):,}/{foundation_common_n:,} patients. The exact three-way intersection contained {ival(foundation_slide_audit.get('exact_common_slides')):,} slides and retained every patient."
    )
    add_table(
        sup,
        ["Representation", "Outcome", "Tasks", "Primary crossings", "Exact-slide crossings", "Lost/gained", "Median change", "Spearman"],
        [[display_representation(r["foundation_model"]), r["outcome_type"], r["tasks"], r["primary_screening_positive"], r["exact_screening_positive"], f"{r['lost_threshold']}/{r['gained_threshold']}", fnum(r["median_delta"],4), fnum(r["spearman_primary_exact"],3)] for r in foundation_exact_slide_sensitivity],
        [2.4, 1.7, 1.2, 2.2, 2.4, 1.8, 2.2, 2.0], font_size=6.8,
        header_font_size=7.0, line_spacing=0.9, fixed_layout=True,
    )

    sup.add_heading("Table S12. Catalogue-normalized representation breadth", 1)
    add_table(
        sup,
        ["Representation", "Outcome", "Task crossings", "Unique definitions", "Macro family %", "Macro cancer %", "Largest family share"],
        [[display_representation(r["foundation_model"]), r["outcome_type"], f"{r['task_crossings']}/{r['eligible_tasks']} ({fnum(r['task_crossing_percent'],1)}%)",
          f"{r['endpoint_definitions_crossing']}/{r['eligible_endpoint_definitions']} ({fnum(r['endpoint_definition_crossing_percent'],1)}%)",
          fnum(r["macro_family_crossing_percent"],1), fnum(r["macro_cancer_crossing_percent"],1),
          f"{r['largest_crossing_family']}: {fnum(r['largest_family_share_of_crossings'],1)}%"]
         for r in sorted(foundation_normalized_breadth, key=lambda x:(x["foundation_model"],x["outcome_type"]))],
        [2.5, 1.6, 3.0, 3.1, 2.0, 2.0, 3.0], font_size=6.8,
        header_font_size=7.0, line_spacing=0.9, fixed_layout=True,
    )
    sup.add_paragraph(
        "Complete family, cancer, endpoint-definition and biological-programme retention tables remain in the normalized-breadth companion files. Counts describe catalogue breadth, not independent biological discoveries."
    )

    sup.add_heading("Table S13. Endpoint-provenance stratification and same-H&E sensitivity", 1)
    add_table(
        sup,
        ["Representation", "Outcome", "Measurement class", "Eligible", "Crossings", "Crossing %"],
        [[display_representation(r["foundation_model"]), r["outcome_type"], r["measurement_class"], r["eligible_tasks"], r["effect_threshold_crossings"], fnum(r["crossing_percent"],1)]
         for r in sorted(foundation_provenance_summary, key=lambda x:(x["outcome_type"],x["measurement_class"],x["foundation_model"]))],
        [2.3, 1.5, 5.0, 1.5, 1.7, 1.8], font_size=6.6,
        header_font_size=6.9, line_spacing=0.9, fixed_layout=True,
    )
    add_table(
        sup,
        ["Representation", "Continuous all", "Continuous excluding same-H&E", "All matched excluding same-H&E"],
        [[display_representation(r["foundation_model"]), f"{r['all_continuous_crossings']}/{r['all_continuous_tasks']}", f"{r['cross_modal_continuous_crossings']}/{r['cross_modal_continuous_tasks']}", f"{r['matched_crossings_excluding_same_histology']}/{r['matched_tasks_excluding_same_histology']}"]
         for r in sorted(foundation_same_histology, key=lambda x:x["foundation_model"])],
        [2.8, 3.2, 5.0, 5.0], font_size=7.0, header_font_size=7.2,
        line_spacing=1.0, fixed_layout=True,
    )
    sup.add_paragraph(
        "CIBERSORT fractions, methylation-derived leukocyte estimates and RNA signatures measure agreement with computational reference phenotypes. The H&E-derived TIL fraction is same-modality concordance and is excluded from the default cross-modal continuous summary."
    )


def _compact_supp_figures():
    if pls2:
        summary = "; ".join(
            f'{r["block"].replace("_", " ")}: mean cancer-level delta Q2 {fnum(r["mean_cancer_delta"])} ({fnum(r["ci_low"])} to {fnum(r["ci_high"])})'
            for r in pls2
        )
        sup.add_paragraph("Separate single-outcome versus joint multi-outcome PLS: " + summary + ". Complete results remain in the synchronized multi-outcome comparison companion.")
    sup.add_page_break()
    add_figure(sup, "FigureS3_binary_class_reliability.png", "Figure S1. Binary class-size reliability, component selection and repeat-score stability for the smaller-class TITAN models.", width=6.25)
    sup.add_page_break()
    add_figure(sup, "FigureS5_continuous_reliability.png", "Figure S2. Continuous sample-size, repeated-prediction stability and component selection. The fewer-than-100-patient label is a denominator descriptor, not an evidence grade.", width=6.25)
    sup.add_page_break()
    add_figure(sup, "Figure6_site_grouped_sensitivity.png", f"Figure S3. Supporting TITAN sensitivity to grouping by TCGA tissue-source-site code. The code is a barcode-derived cohort variable, not an institution, scanner or laboratory identifier.", width=6.25)
    sup.add_page_break()
    add_figure(sup, "FigureS12_paired_representation_effects.png", "Figure S4. Paired Q2 and AUROC estimates for all 3,389 matched cancer-endpoint tasks. The comparison is conditional on the specified common probe.", width=6.25)
    sup.add_paragraph("The two COAD PathoFMPred examples now appear at readable size in main Figures 5 and 6 and are not duplicated in this shortened Supplement.")
    sup.add_page_break()


def _compact_machine_inventory():
    sup.add_paragraph(
        "The repository retains complete-resolution records. The groups below replace the former multi-page filename list; source_manifest.csv and software_manifest.csv provide the exact inventory and checksums."
    )
    for item in (
        "Matched representation atlas: foundation_model_*.csv and results/predictions/foundation_model_*.rds",
        "Supporting TITAN screen: continuous_screen.csv, binary_screen.csv and repeated nested-validation files",
        "Permutation and multiplicity: permutation_*.csv, targeted_permutation_*.csv and multiplicity_*.csv",
        "Tissue-source-site-code analyses: site_grouped_*.csv, tissue_source_site_*.csv and foundation_model_tss_*.csv",
        "Reliability and operating rules: binary_*.csv and continuous_reliability_*.csv",
        "Pathology, pooling and linkage: pathology_qc_*.csv, slide_embedding_*.csv, *_pooling_sensitivity.csv and molecular_slide_linkage_audit.csv",
        "Endpoint provenance and literature: endpoint_*.csv, outcome_source_acquisition_map.csv and *_literature_*.csv",
        "Software and fitted-object audits: models/model_registry.csv, fitted_model_*.csv and data/reference/software_access_licensing_matrix.csv",
        "PathoFMPred COAD examples: coad_pathofmpred_multifoundation_*.csv and Additional files 2-3",
        "Reproducibility manifests: source_manifest.csv, software_manifest.csv and data/reference/analysis_chronology.csv",
    ):
        p = sup.add_paragraph(item, style="List Bullet")
        p.paragraph_format.space_after = Pt(0)


_replace_block(sup, "Contents", "Supplementary Methods", _compact_supp_contents)
_replace_block(sup, "Table S1. Analysis coverage", "Secondary single-outcome and multi-outcome PLS results", _compact_supp_tables_revised)
_replace_block(sup, "Secondary single-outcome and multi-outcome PLS results", "Machine-readable additional files", _compact_supp_figures)
_replace_after_heading(sup, "Machine-readable additional files", _compact_machine_inventory)

for paragraph in sup.paragraphs:
    if paragraph.text.strip() == "Table S1. Analysis coverage":
        paragraph.text = "Table S1. Analysis coverage and evidence layers"
    elif paragraph.text.strip() == "Secondary single-outcome and multi-outcome PLS results":
        paragraph.text = "Supplementary Figures"

replace_reader_facing_chronology_terms(sup)
standardize_matched_evidence_terms(sup)
standardize_released_pipeline_terms(sup)
standardize_tissue_source_site_terms(sup)
standardize_sample_size_maturity_terms(sup)
standardize_literature_audit_terms(sup)
remove_em_dashes(sup)
sup.save(OUT / "supplementary_material_JTM.docx")


# Point-by-point response
resp = setup(Document(), "Response to reviewer — multi-foundation-model atlas")
resp.add_heading("Response to reviewer", 0)
resp.add_paragraph("Manuscript: " + MANUSCRIPT_TITLE)
resp.add_paragraph("We thank the reviewer for identifying validation and reproducibility as the principal issues. The analysis has been rebuilt from the original files with patient-first slide aggregation and primary-tumour molecular matching.")

responses = [
    ("1. The manuscript needs a much clearer hierarchy of analyses and evidence",
     f"Agreed. We now identify one primary contribution and two supporting resource layers consistently across the Abstract, Background, Methods, Results, Discussion and Conclusions. The primary layer is the retrospective matched three-representation benchmark on 8,241 patients and 1,933 cancer-endpoint pairs. Its Q²≥0.20 and AUROC≥0.60 counts are descriptive effect-threshold crossings without representation-specific permutation/FDR qualification, while Q² and AUROC are the primary continuous and binary representation-comparison statistics. It includes five alternative matched partitions for an effect-threshold-crossing or near-threshold audit set. The secondary layer is the larger permutation/FDR-filtered internal TITAN screen on 9,404 patients and 2,073 eligible pairs; {titan_candidate_total} candidates met both effect and empirical-permutation/FDR criteria and entered separate five-repeat and TCGA tissue-source-site-code-grouped analyses. The tertiary PathoFMPred layer creates no new performance evidence: its {registry_object_total} controlled fitted objects retain the representation, evidence qualification, validation scope and access status of the generating layer. The Methods state the cohort and task universe, representation scope, statistic and inferential status of each layer, and the Results follow the same hierarchy. We also removed the ambiguous description of the full TITAN universe as the article's 'primary screen'; 'primary screening estimate' remains only as a TITAN-layer label distinguishing the initial estimate from its five-repeat stability estimate."),
    ("1. The novelty relative to existing pan-cancer studies must be defined much more sharply",
     "Agreed. We changed the title and abstract to frame the work as a systematic patient-level multi-foundation-model atlas with a reproducible analysis interface and model registry, not a first pan-cancer histology-to-molecular screen or a complete fitted-model prediction resource. The Background now quantifies the closest precedents: Fu et al. analysed 17,355 slides across 28 cancers; Kather et al. used more than 5,000 patients across 14 cancers; Saldanha et al. externally tested mutation models in seven matched TCGA/CPTAC cancers; and Arslan et al. trained 12,093 models for 4,031 biomarkers in 8,890 TCGA patients across the same 32 cancers. The detailed literature audit remains in Supplementary Table S11 and data/reference/pan_cancer_benchmark_comparison.csv. The abstract and Discussion state that 38/41 screen-positive TITAN cancer–gene pairs had prior statistical support. We make no general mutation-target novelty claim; the distinctive contribution is the matched patient-level atlas across TITAN, Giga-SSL and Prov-GigaPath under a fixed probe, deterministic pre-outcome patient aggregation, nested validation, negative and ineligible outputs, tissue-source-site-code sensitivity and explicit software/access metadata."),
    ("Audit comment: continuous repeated cross-validation returned negative Q² and near-zero correlation",
     "Confirmed and corrected. fastPLS returns continuous predictions as an n-by-1-by-1 array. The previous repeated-validation helper used Ypred[[1]], which extracted one scalar and silently recycled it across every patient in the held-out fold. The revised helper drops only singleton dimensions, verifies that the prediction length equals the held-out patient count, and then assigns one prediction per patient. A targeted COAD TIL Regional Fraction check agreed with pls.double.cv (corrected Q² 0.430 and Spearman 0.701 versus 0.377 and 0.655 with the independent routine). We invalidated the affected analysis fingerprint and regenerated all repeated continuous predictions, summaries, uncertainty intervals, reference distributions, figures and reports. Across the 219 screen-positive continuous models, corrected mean repeated-CV Q² values are now positive, with median Q² 0.300 and median Spearman correlation 0.553."),
    ("Audit comment: continuous radar reference positions inherited the broken predictions",
     "Confirmed. The fitted full-cohort predictions were not affected, but the TCGA out-of-fold reference distributions used for radar positions were. PathoFMPred's prediction_reference.rds was rebuilt from the corrected repeated held-out predictions, the package was reinstalled, and the COAD reports and Figure 8 were regenerated. The original model prediction remains printed at every radar corner."),
    ("3. Site sensitivity is a central result, not a supplementary robustness check",
     f"Addressed as a principal analysis. Main Figure 7 now has three panels: all {titan_candidate_total} random-fold versus results grouped by TCGA tissue-source-site code; the largest target-level attenuations, including READ–APC (balanced accuracy {fnum(read_apc_site.get('random_balanced_accuracy'), 3)} to {fnum(read_apc_site.get('site_grouped_balanced_accuracy'), 3)}) and COAD–APC ({fnum(coad_apc_site.get('random_balanced_accuracy'), 3)} to {fnum(coad_apc_site.get('site_grouped_balanced_accuracy'), 3)}); and the within-cancer prediction analysis of TCGA tissue-source-site code. Complete highlighted-model grouped metrics and warning status are in Supplementary Table S6a rather than an oversized main-text table. The public analysis registry and access-controlled PathoFMPred registry contain the grouped metric, delta, number of TCGA tissue-source-site codes, threshold-retention flag, near-chance flag, validation scope and warning for all {titan_candidate_total} models; inference outputs and reports display these fields and prominently warn about models sensitive to grouping by TCGA tissue-source-site code. We report that {ival(site_combined.get('below_threshold_models'))}/{ival(site_combined.get('screen_positive_models'))} models ({fnum(site_combined.get('below_threshold_percent'), 1)}%) fell below the original threshold: {sum(float(r.get('site_grouped_q2') or float('-inf')) < 0.20 for r in site_c if r.get('feasible') == 'TRUE')}/{len(site_c)} continuous and {sum(float(r.get('site_grouped_balanced_accuracy') or float('-inf')) < 0.60 for r in site_b if r.get('feasible') == 'TRUE')}/{len(site_b)} binary. The fold audit provides all {len(site_fold_details):,} outer-fold compositions with test/training patients, TCGA tissue-source-site codes, positive and negative cases, code identifiers and seeds; selected APC folds appear in Table S10c. We confirmed from both the implementation and deterministic fold reconstruction that the constraint on TCGA tissue-source-site code was passed to inner component selection as well as outer evaluation, with no code overlap. In the five-repeat nested PLS–LDA analysis, TITAN predicted TCGA tissue-source-site code in {len(site_predictability_eligible)}/32 evaluable cancers; median multiclass macro balanced accuracy was {fnum(median([r.get('macro_balanced_accuracy_mean') for r in site_predictability_eligible]))}. We consistently call the endpoint sensitivity 'internal validation grouped by TCGA tissue-source-site code' and state that the barcode-derived code is not an institution, scanner or laboratory identifier; neither retained performance nor code classification proves institutional or scanner-level transportability."),
    ("Audit comment: mutation novelty was overstated",
     f"Confirmed. The exact-code crosswalk missed pooled colorectal studies and did not include newer pan-cancer source data. We expanded the audit using Kather et al., Saldanha et al., Arslan et al. and a clearly labelled ovarian preprint. Of {len(mutation_literature_audit)} screen-positive mutation pairs, {len(prior_supported_mutations)} were previously supported, {len(prior_evaluated_not_supported)} had been evaluated without statistical support, and only THYM–GTF2I was not identified in the reviewed predictive-model literature. All 'atlas-nominated' novelty language was removed. The revised Table S10a records evidence class, cancer scope, prior metric, source and note for every pair."),
    ("Audit comment: PLS lacked a simple exportable baseline",
     f"Superseded by a stronger representative benchmark selected without PLS performance. All {len(continuous)+len(binary):,} eligible tests entered a metadata-only sampling frame, and a fixed salted SHA-256 rank selected one target from every non-empty outcome-family × sample-size-tercile cell, with an additional minority-class-fraction tercile for binary outcomes. The resulting {len(ridge_comparison)} targets comprise {len(ridge_continuous)} continuous and {len(ridge_binary)} binary endpoints, of which only {len(ridge_screen_positive)} were screen-positive. Median ridge-minus-PLS differences were {fnum(continuous_baseline_summary.get('median_delta_ridge_minus_pls'))} Q² and {fnum(binary_baseline_summary.get('median_delta_ridge_minus_pls'))} AUROC. We make no PLS-superiority claim; Table S10e and machine-readable files report the sampling frame, hashes, jobs, folds, predictions and paired intervals."),
    ("4. The binary modelling and ridge comparison use asymmetric decision rules",
     f"Confirmed and corrected. The representative benchmark contains {len(ridge_binary)} binary comparisons across five repeats. PLS–LDA and ridge receive identical outer and inner folds; each operating threshold is selected from that method's inner out-of-fold score by the identical balanced-accuracy rule. Threshold-independent AUROC is primary and symmetrically thresholded balanced accuracy secondary. The median ridge-minus-PLS AUROC difference was {fnum(binary_baseline_summary.get('median_delta_ridge_minus_pls'))} (IQR {fnum(binary_baseline_summary.get('q1_delta'))} to {fnum(binary_baseline_summary.get('q3_delta'))}); {sum(r.get('outcome_type') == 'binary' for r in ridge_better)} targets favoured ridge, none favoured PLS and {sum(r.get('outcome_type') == 'binary' for r in baseline_uncertain)} were uncertain. For balanced accuracy, {len(binary_secondary_ridge)} favoured ridge, {len(binary_secondary_pls)} PLS and {len(binary_secondary_uncertain)} were uncertain. Continuous PLS components and ridge penalties likewise use identical folds and maximise the same pooled inner out-of-fold Q². Complete repeat-level results record fold and tuning symmetry."),
    ("4a. The primary binary decision rule is not well aligned with balanced accuracy",
     (
         "Agreed; this required a complete analysis rather than a wording change. We reran every eligible binary pair on the original outer partitions under three nested rules: the documented empirical-training-prior LDA call, equal LDA priors, and a component-specific operating threshold selected from pooled inner held-out scores to maximise balanced accuracy. The alternative rules reselected component count within each outer training set; no outer-test label entered tuning. The Methods now state the exact pooled inner objective and that component ties select the smallest count; threshold ties prefer a finite value and then the value nearest zero. In the 459-pair TITAN screen universe, empirical/equal/optimized rules produced "
         f"{ival(titan_decision_all.get('baseline_empirical_prior_crossings'))}/{ival(titan_decision_all.get('equal_prior_crossings'))}/{ival(titan_decision_all.get('optimized_crossings'))} balanced-accuracy crossings; the optimized rule retained {ival(titan_decision_all.get('baseline_retained_optimized'))}, lost {ival(titan_decision_all.get('baseline_lost_optimized'))} and gained {ival(titan_decision_all.get('optimized_gained'))}. "
         f"Of the {len(titan_optimized_gains)} optimized-rule TITAN gains, {titan_optimized_gains_limited} had fewer than 50 patients in the minority class, so the alternative rule cannot be interpreted as simply revealing more mature signals. The same complete sensitivity was run for all 426 matched binary pairs in each of TITAN, Giga-SSL and Prov-GigaPath. Because the crossing counts changed materially, threshold-independent AUROC is now the primary binary representation-comparison statistic; balanced-accuracy crossings remain descriptive coverage summaries. We explicitly disclose that the primary matched-atlas AUROC evaluates the continuous score from the documented empirical-prior balanced-accuracy-selected component: it removes the final class cut-off but does not make the downstream tuning probe irrelevant. Main Table 2 shows empirical/equal/optimized counts for every representation, while Supplementary Table S10i and four machine-readable files report sensitivity, specificity, balanced accuracy, AUROC, PR-AUC, selected components and thresholds for every rule and outer fold. Newly gained TITAN threshold crossings are not called permutation/FDR-qualified candidates because the permutation procedure was not silently reused under a different decision rule. The registry carries an operating-rule-sensitivity field and warning. During this audit we also detected that cached binary outputs predated the installed fastPLS Git revision despite sharing its package version string; the cache fingerprint now includes the Git SHA, the primary balanced-accuracy screen was reproduced before interpreting the rule comparison, and all permutation and dependent binary outputs were regenerated for the synchronized revision."
     )),
    ("5. The multiplicity framework is thoughtful but remains resolution-limited",
     f"Addressed at the analysis and reporting levels. We now state unambiguously that every patient-label permutation reruns the complete nested modelling process: training-fold centering, inner five-fold selection of 1–10 components, outer-fold refitting and held-out prediction. No scaling parameter, selected component count or outer prediction is reused from the observed-label model. For every completed permutation test we added exact two-sided 95% Clopper–Pearson Monte Carlo bounds for the underlying null exceedance probability. Among completed 999-permutation tests, {len(zero_999)} had zero exceedances; their finite empirical p-value is 0.001 but the interval is 0–{fnum(zero_999_upper, 6)}. Conservatively early-stopped tests retain p=1 and are explicitly marked as censored rather than given a precision interval. Before generating high-resolution results, we locked TGCT TGF-beta Response, THYM Th17 Cells, THCA Lymphocyte Infiltration Signature Score, BRCA Wound Healing, COAD APC, THYM GTF2I, COAD strict MSI-H and UCEC any-called-fusion; the registry was recorded in Git commit ac30ccb before the result table existed. We continued their saved deterministic permutation streams from 999 to 9,999 complete-process permutations. {len(targeted_zero)}/{len(targeted_permutation)} had zero exceedances; refined p-values were {targeted_p_summary}. These refined values are reported as a targeted precision sensitivity and were not substituted into the original FDR screen documented in the initial repository snapshot. We also added outcome-wide and single atlas-wide BH sensitivities. Of {ival(combined_multiplicity.get('within_cancer_family_candidates'))} locally controlled candidates, {ival(combined_multiplicity.get('atlas_wide_pass'))} passed one BH correction across all {ival(combined_multiplicity.get('eligible_tests')):,} eligible tests. The manuscript now says explicitly that the aggregate candidate count is not itself a single global 5% FDR result. Figures and tables are ordered by the outcome-appropriate predictive metric, with repeated stability and stability under grouping by TCGA tissue-source-site code reported alongside; tied permutation q-values are not used for ranking. Full endpoint-level uncertainty, atlas-wide q-values, the locked target registry and 9,999-permutation results are supplied in machine-readable files and Supplementary Table S10f."),
    ("6. The minimum binary class requirement is too permissive for headline and distributed models",
     f"Agreed. We retained the documented 20-per-class rule only for an inclusive, fully reported atlas screen, and added a separate ≥50-per-class evidence standard. Of {ival(binary_sensitivity_20.get('eligible_binary_targets'))} eligible binary cancer–endpoint pairs, {ival(binary_sensitivity_50.get('eligible_binary_targets'))} ({fnum(binary_sensitivity_50.get('eligible_target_retention_percent'), 1)}%) met the stricter rule. Of {len(supported_b)} screen-positive binary models, {len(binary_standard)} ({100 * len(binary_standard) / max(1, len(supported_b)):.1f}%) met it; the remaining {len(binary_limited_reliability)} are now labelled exploratory/limited evidence and excluded from default PathoFMPred inference. None of the main highlighted binary models is limited evidence. For all {len(supported_b)} candidates we released all {len(binary_fold_counts):,} repeated outer-fold class counts, all {len(binary_component_summary) * 25:,} outer-fit component selections with reconstructed inner-fold class minima, repeat-specific PR-AUC, TCGA-prevalence PPV/NPV, and score/call stability. The smallest outer test fold contained {binary_min_outer_positive} positive and {binary_min_outer_negative} negative patients; within the limited subset the exact inner partitions contained as few as {limited_min_inner_training_positive} positive training and {limited_min_inner_validation_positive} positive validation patients. For all {len(binary_limited_reliability)} limited models we ran fixed-outer-test learning curves at 50%, 75% and 100% of the training data. Median balanced accuracy was {fnum(binary_learning_50.get('balanced_accuracy'))}, {fnum(binary_learning_75.get('balanced_accuracy'))} and {fnum(binary_learning_100.get('balanced_accuracy'))}; median AUROC was {fnum(binary_learning_50.get('auc'))}, {fnum(binary_learning_75.get('auc'))} and {fnum(binary_learning_100.get('auc'))}. Supplementary Table S10g and Figure S1 show endpoint-level counts, PR-AUC, predictive values, components, learning curves and repeat stability. The registry and inference output expose the evidence tier, default status and reliability metadata; explicit opt-in to a limited model emits a warning. PPV/NPV are labelled cohort-specific and the binary score remains explicitly uncalibrated and not a probability."),
    ("7. Reported uncertainty is conditional and does not capture the entire modelling process",
     f"Agreed. Every main and supplementary performance-table heading now uses '95% SC interval', defined in full as a '95% selection-conditioned patient-resampling interval for repeated out-of-fold predictions'. For highlighted atlas models, 1,000 bootstrap replicates retain five existing held-out prediction sets; the Methods enumerate the omitted screening, repartitioning, tuning, refitting, winner's-curse and external-institution components. The PLS–ridge comparison uses 2,000 paired patient-resampling replicates and the exact d_r and Δ construction requested. Its interval is now conditional on the metadata-stratified benchmark sample—not PLS-based highlighting—and does not regenerate partitions or refit models. Matched patient-level predictions and all {len(ridge_comparison)*5} repeat-specific differences are released. Paired primary-metric intervals favoured ridge for {sum(r.get('outcome_type') == 'binary' for r in ridge_better)} binary and {sum(r.get('outcome_type') == 'continuous' for r in ridge_better)} continuous comparisons, PLS for none."),
    ("8. The justification for retaining PLS as the central model is currently insufficient",
     f"Agreed with the premise: the revision no longer describes PLS as the best or uniquely portable method. We replaced the PLS-highlighted comparison with a {len(ridge_comparison)}-target representative benchmark selected solely by outcome family, empirical sample-size tercile, binary minority-class-fraction tercile and a fixed salted hash. PLS and ridge use identical folds and identical tuning objectives. Median ridge-minus-PLS differences were {fnum(binary_baseline_summary.get('median_delta_ridge_minus_pls'))} AUROC and {fnum(continuous_baseline_summary.get('median_delta_ridge_minus_pls'))} Q²; paired intervals favoured ridge for {sum(r.get('outcome_type') == 'binary' for r in ridge_better)}/{len(ridge_binary)} binary and {sum(r.get('outcome_type') == 'continuous' for r in ridge_better)}/{len(ridge_continuous)} continuous targets, PLS for none. We therefore retain PLS only as the documented reference analysis and label the fitted PLS resource accordingly; portability is explicitly stated to apply to ridge as well. Multi-outcome PLS remains secondary because it covers only coherent continuous inflammatory panels, uses complete-case intersections and a fixed ordered response block, shares latent structure across responses, and cannot replace individual binary mutation/pathway/MSI/aneuploidy/fusion models. Its mean cancer-level ΔQ² values of 0.066, 0.017 and 0.056 support future multi-outcome immune modelling whose evaluation rules should be committed before outcome inspection, but not replacement of the endpoint-specific resource without external validation and a matched multi-outcome baseline."),
    ("9. Derived immune phenotypes, endpoint provenance and morphological context",
     f"Agreed and addressed at the analysis, manuscript and supplementary-data levels. We no longer use 'immune measurements' as an undifferentiated label. Every one of the {len(endpoint_dictionary):,} eligible cancer–endpoint tests is classified as a directly observed genomic alteration, sequencing-derived continuous burden, computationally inferred immune-cell fraction, transcriptomic signature, pathology-associated quantity or composite genomic-context score. The new endpoint_dictionary.csv records source modality, direct/inferred status, derivation algorithm, original scale, analysis transformation, analysed and missing patients, expected measurement error, biological interpretation, assay-equivalence caveat and source reference for every target; endpoint_definition_dictionary.csv provides {len(endpoint_definitions)} unique definitions. The Methods and Discussion now distinguish RNA-seq CIBERSORT deconvolution, methylation-derived leukocyte fraction, RNA signatures, repertoire reconstruction, predicted neoantigens, copy-number/purity scores and directly called alterations. TIL Regional Fraction is explicitly labelled a Saltz H&E-derived same-modality concordance target. We state that predicting an inferred score is not equivalent to flow cytometry, IHC, a direct immune-cell count or a clinically certified biomarker. Supplementary Table S13 summarises the classes and derivations while designating the full 2,073-row CSV as the complete target-level dictionary. For morphology, we added five representative high/low repeated-OOF anchor analyses spanning BLCA TIL Regional Fraction, TGCT Macrophages M2, BRCA Wound Healing, UCEC Aneuploidy score and THYM GTF2I. Supplementary Table S14 and morphology_context_examples.csv retain the exact patient and slide identifiers, observed and predicted values, ranks, cosine similarities and generated-report context. Because only global pooled embeddings and automated same-slide reports were available, we explicitly describe this as qualitative neighbour retrieval, not patch relevance, causal morphology or blinded pathologist review, and identify tile-level attribution plus independent pathology review as required future work."),
    ("10. The COAD single-sample demonstration risks overinterpretation",
    "Partly agreed. At the authors' request, the two COAD participants remain in the main manuscript as a PathoFMPred software example. Main Figure 3 now applies the three representation-specific fitted resources to TITAN, Giga-SSL and Prov-GigaPath inputs for both TCGA-AA-A01F and TCGA-A6-A56B. It displays six continuous COAD endpoints available for all three resources, keeps endpoint order fixed across all six panels and prints the original prediction values at every radar corner. The radar radius is labelled as an internal TCGA reference percentile for display only and not a probability. The Supplement states that both cases had sigmoid-colon, moderately differentiated pT3 adenocarcinoma with uninvolved margins, while TCGA-AA-A01F was pN1 and the available report for TCGA-A6-A56B did not state nodal category. Treatment and outcome narratives remain excluded because they were not model inputs or validation outcomes. The figure is described as an interface illustration, not representative sampling, calibration, external validation or clinical interpretation."),
    ("Audit comment: the Introduction did not state the gap",
     "Addressed. The Background now states explicitly that breadth is not the gap after the large pan-cancer studies by Fu, Kather, Saldanha and especially Arslan. It defines the narrower gap as a reproducible patient-level benchmark of three released representation pipelines using deterministic slide aggregation, one common nested analysis framework, complete negative and ineligible reporting, target-level sensitivity to grouping by TCGA tissue-source-site code and a secondary research-software registry."),
    ("Audit comment: binary percentiles could be mistaken for probabilities and small classes were not visible",
     "Addressed by relabelling rather than adding an unevaluated post-hoc calibration layer. Binary displays use 'TCGA out-of-fold score rank (not probability)', retain the raw uncalibrated LDA score and class call, and show training class counts and prevalence, balanced accuracy, AUROC, PR-AUC, TCGA-prevalence PPV/NPV, fold minima, component variability and repeat stability. Models below 50 patients in either class are no longer merely warned: they are excluded from default inference, marked exploratory/limited evidence throughout, and require explicit opt-in that emits a warning. Proper probability calibration remains future work requiring independently evaluated or fully nested calibration."),
    ("1. Across-cancer multiplicity and permutation resolution",
     f"Addressed. Every endpoint meeting the documented screening-statistic threshold is refined toward 999 complete-process patient-label permutations with a conservative stopping boundary of 49 exceedances, minimum completed-test resolution 0.001 and exact attempted counts retained. The within-cancer/family q-value documented in the initial repository snapshot and the revision-added across-cancer family, outcome-wide and single atlas-wide q-values are reported in separate machine-readable fields. Exact Monte Carlo intervals and the targeted 9,999-permutation refinement make the remaining resolution limitation explicit. The abstract, figures and Discussion distinguish locally controlled candidates from the {ival(combined_multiplicity.get('atlas_wide_pass'))}/{ival(combined_multiplicity.get('within_cancer_family_candidates'))} that also pass the single atlas-wide sensitivity; non-passage is not treated as evidence of absence."),
    ("2. External validation is the principal unresolved limitation",
     "We agree that this is the central unresolved limitation. The official TITAN release provided the TCGA embeddings used here, but our audit found no compatible non-TCGA precomputed TITAN representation with the required outcomes; no independent patient entered analysis. CPTAC-UCEC is a realistic future cohort because its official TCIA collection reports 250 subjects, 887 pathology slides (approximately 154 GB) and linked molecular resources, but de novo TITAN extraction and exact endpoint harmonisation are required and were not performed. We therefore adopted the reviewer's computational-resource fallback throughout: 'deployment', 'patient molecular profile' and 'prediction report' language was removed; Figure 8 is retained only as a post hoc research-software visualization with an explicit no-validation caption; and all numerical outputs are labelled internally derived TCGA estimates. The abstract, intended use, Discussion and Conclusions state that there is no external performance evidence or basis for clinical interpretation. To prevent future target or threshold cherry-picking, we prospectively locked three UCEC artifacts before inspecting any external features or outcomes: TP53 mutation, genome doubling and continuous aneuploidy score. Their exact SHA-256 hashes, endpoint-compatibility rules and metrics are in Supplementary Table S6c, docs/EXTERNAL_VALIDATION_PROTOCOL.md and data/reference/external_validation_locked_targets.csv rather than the main Results. The future protocol requires exact TITAN extraction, identical patient pooling, no refitting, recalibration or threshold adjustment, and reporting of every target including failures and non-evaluable endpoints. We explicitly state that locking a protocol is not external validation."),
    ("Additional site-sensitivity coverage across endpoint families",
     f"Validation grouped by TCGA tissue-source-site code is attempted for every within-cancer screen-positive continuous and binary endpoint, not only mutations. It was feasible for {sum(r.get('feasible')=='TRUE' for r in site_c)+sum(r.get('feasible')=='TRUE' for r in site_b)} models. Figure 6, Table S10b and the complete machine-readable tables report target-level attenuation across immune, genomic-context, MSI, aneuploidy, fusion, pathway and mutation families."),
    ("4. Reproducibility materials must be deposited before submission",
     f"The analysis repository ({REPO}) remains public and contains the analysis plan, source URLs and checksums, software commit, eligibility tables, code, out-of-fold outputs, literature crosswalk, model registry and locked external-evaluation protocol. PathoFMPred source code is public at {MODEL_REPO} under MIT. The public package contains a minimal Giga-SSL fixture and checksum-verified, user-invoked downloads of the Giga-SSL and Prov-GigaPath fitted collections under separate asset notices and upstream attribution. The TITAN fitted collection remains only in the private PathoFMPred-private repository pending written redistribution permission. A persistent DOI remains a future release action after author approval of the synchronized snapshot."),
    ("5. Distinguish cancer genes from functional driver alleles",
     "Addressed throughout. Mutation targets are described as qualifying protein-altering PASS mutations in tissue-specific consensus cancer genes; the manuscript explicitly states that not every allele is functionally validated."),
    ("6. Preserve effect-size-first interpretation of multi-outcome PLS",
     "Addressed. The comparison of separate single-outcome and joint multi-outcome PLS is now confined to the Supplementary Methods and machine-readable result summary. It remains restricted to coherent inflammatory blocks, uses identical patients and folds, and is interpreted by cancer-level ΔQ² with bootstrap intervals rather than win counts. Binary molecular endpoints retain one-at-a-time PLS-LDA as the primary analysis."),
    ("7. Complete submission-specific fields",
     "Partly outstanding. Aamilah Ismail and Martin Ocharo are listed as shared co-first authors, with Martin Ocharo second in the author order and assigned to affiliations 1 and 2. Brendon Price is included in the middle of the author list with the Division of Anatomical Pathology, University of Cape Town and National Health Laboratory Service affiliation. Silvano Piazza, Dinesh Gupta, Alessia Vignoli and Leonardo Tenori are listed before Stefano Cacciatore. Silvano Piazza has dual affiliations with the ICGEB Computational Biology Group in Trieste and the Bioinformatics Facility, CIBIO, University of Trento; Dinesh Gupta has the ICGEB New Delhi affiliation; and Alessia Vignoli and Leonardo Tenori have the Department of Chemistry 'Ugo Schiff' and Magnetic Resonance Center affiliations at the University of Florence. The remaining supplied author names, affiliations, available email addresses and corresponding-author details have been entered. Email addresses for Martin Ocharo, Brendon Price, Ekene Emmanuel Nweke, Silvano Piazza and Dinesh Gupta were not supplied. Funding, competing interests and contribution statements still require author confirmation and remain visibly marked where applicable. No scientific values are placeholder text."),
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
     "Highlighted binary models report sensitivity, specificity, balanced accuracy and AUROC; highlighted continuous models report Q², RMSE and Spearman correlation, with explicitly labelled selection-conditioned patient-resampling intervals for repeated out-of-fold predictions. Research-use provenance includes feature checksums and ranges, class coding and priors, decision rule, calibration status, external-validation status and intended use. Supplementary Figure S7 compares held-out predictions directly with observed data without foregrounding a best-case example. Main Figure 8 and the two separate PDF attachments (Additional files 2 and 3) remain post hoc software-interface visualizations labelled internally derived, uncalibrated and not externally validated."),
    ("Additional change: rSVD-only PLS decomposition",
     "All primary, permutation, repeated, validation grouped by TCGA tissue-source-site code, slide-pooling, single-outcome versus multi-outcome PLS and final-model fits use CPU rSVD with 10 oversampling vectors, two power iterations and fixed seeds. Solver identity and controls are recorded in screening, sensitivity and model-registry metadata and verified against saved-model diagnostics."),
    ("Effect terminology",
     f"Agreed. We replaced 'higher effect' and 'moderate effect' throughout the manuscript, figures, tables, software report and machine-readable performance summary with the neutral labels 'screening tier A' and 'screening tier B'. The Methods define tier A as primary q<0.05 with Q²≥0.40 for continuous outcomes or balanced accuracy≥0.70 for binary outcomes, and tier B as primary q<0.05 with Q² from 0.20 to <0.40 or balanced accuracy from 0.60 to <0.70. We state explicitly that these are documented prioritisation rules, not established clinical or statistical effect categories, and that Q² and 2×balanced accuracy−1 are not interpreted as directly commensurate. The abstract, Results and Discussion also report that {len(global_supported_c)} continuous and {len(global_mutation_b)} cancer–mutation pairs passed the across-cancer family correction and that {ival(combined_multiplicity.get('atlas_wide_pass'))}/{ival(combined_multiplicity.get('within_cancer_family_candidates'))} local candidates passed a single BH correction across all eligible atlas tests."),
    ("Primary versus repeated estimates",
     "Agreed and clarified throughout. We now reserve 'primary screening estimate' for the initial nested-CV value used for candidate selection, permutation testing and tier assignment, and 'repeated-validation estimate' for the arithmetic mean across five additional independently seeded nested-CV partitions. The Methods explain that different folds and rSVD seeds make numerical differences expected and that the repeated estimate describes post-selection stability without replacing the primary screen. THYM–Th17 is stated explicitly as primary screening Q²=0.638 versus five-repeat mean Q²=0.594. Supplementary Table S6a presents both estimates side by side; the abstract, Results, figure captions and Supplementary Tables S6a–S10b label the relevant stage. Machine-readable summaries include explicit primary-screen fields, repeated fields, estimate labels and the repeated-minus-primary difference."),
    ("Manuscript length and table density",
     "Agreed. The review-style literature comparison remains in Supplementary Table S11 and the machine-readable crosswalk rather than the main article. The oversized highlighted-model performance table likewise remains in Supplementary Table S6a. The compact main tables now present only the central multi-representation atlas, provenance, concordance and slide-intersection results."),
    ("Report precision–recall metrics",
     f"Agreed. PR-AUC is calculated as non-interpolated average precision from held-out continuous LDA scores in each repeated nested-CV run, and its no-skill reference is explicitly defined as the observed endpoint prevalence. The Abstract now reports PR-AUC for the highlighted binary model. The main Results summarize all {len(binary_reliability)} screen-positive binary models and show the prevalence-dependent contrast directly: the {len(low_prevalence_mutation_fusion)} mutation or fusion endpoints below 20% prevalence had median prevalence {fnum(median(r.get('observed_tcga_prevalence') for r in low_prevalence_mutation_fusion))}, median PR-AUC {fnum(median(r.get('repeated_pr_auc_mean') for r in low_prevalence_mutation_fusion))} and median AUROC {fnum(median(r.get('repeated_auc_mean') for r in low_prevalence_mutation_fusion))}. Endpoint-level PR-AUC, repeat variability, prevalence and class counts remain in Supplementary Tables S6a, S8 and S10g, the model registry and PathoFMPred output."),
    ("Figure readability",
     f"Agreed. Figures 2 and 3 split the formerly dense four-panel foundation-model comparison into two readable figures. Figure 4 moves the central TITAN tissue-source-site-code sensitivity forward, retains all {titan_candidate_total} candidates only in its overview, and limits the attenuation and code-classification panels to six and 10 results. Figures 5 and 6 show 12 TITAN models with enlarged typography. Figure 7 uses normalized cancer-specific crossing rates rather than raw counts. The strongest selected prediction examples moved to Supplementary Figure S7. At the authors' request, main Figure 8 retains two radar plots with original predictions printed at every corner, corrected TCGA out-of-fold reference positions, sample IDs and explicit internal-only warnings."),
    ("Move implementation detail out of the main Results",
     "Agreed. The PathoFMPred inventory, input schema, pooling behaviour, score-rank construction, checksums, class counts, reliability warnings, report-generation behaviour, synthetic smoke test, locked-target details and artifact metadata have been removed from the main Results. These materials remain in Supplementary Methods, Tables S6b–S6c and S13, the machine-readable registries and package documentation. The implementation-oriented 'External-validation readiness audit' subsection and the software-construction paragraph have been deleted. The main Results retain only a short 'Illustrative COAD research-software profiles' section with the post hoc selection caveat and Figure 8, as requested by the authors."
    ),
    ("Clarify the site variable",
     "Agreed. We now use 'TCGA tissue-source-site code' whenever referring to the two-character barcode field. Analyses are described as 'internal validation grouped by TCGA tissue-source-site code' and 'within-cancer classification of TCGA tissue-source-site code'; fold counts are counts of codes rather than sites. The Abstract, Methods, Results, Discussion, Figure 6 caption, Supplementary Tables S6a and S10b–S10d, reviewer report and response have been standardised. We state explicitly that this barcode-derived code is not an institution, scanner, laboratory or staining-batch identifier and that grouping by it is not external validation. Uses of 'site' with a different biological meaning, such as splice site or resection site, were retained."),
    ("Additional change: TRIPOD+AI and fairness reporting",
     f"Supplementary Table S12 maps every TRIPOD+AI item to the manuscript or repository. We now add a denominator-first post hoc subgroup audit using the fixed five-repeat held-out predictions. A high-volume model required at least 200 outcome-labelled patients; continuous subgroup metrics required at least 50 patients, and binary metrics required at least 20 positive and 20 negative patients. Both recorded-sex groups were estimable in {subgroup_two_group_models['continuous_sex']} continuous and {subgroup_two_group_models['binary_sex']} binary models; at least two broad race groups were estimable in {subgroup_two_group_models['continuous_race']} continuous and {subgroup_two_group_models['binary_race']} binary models. Supplementary Table S2b gives exact counts for highlighted models, while subgroup_performance_audit.csv reports exact counts, metrics or the specific non-estimability reason for every screen-positive model–subgroup row. The manuscript states that these post hoc internal estimates are not formal fairness validation and do not establish demographic equivalence."),
    ("Additional change: selection-conditioned uncertainty",
     "The Methods, tables and Discussion now use the explicit label 'selection-conditioned patient-resampling interval for repeated out-of-fold predictions' and enumerate included and excluded uncertainty components. These intervals condition on endpoint selection and five fixed nested-CV prediction sets; they do not remove winner's-curse optimism, repeat screening or refitting, or represent external performance."),
    ("Pathology quality control",
     f"Agreed and addressed with a structured-field audit and explicit limitation. Neither the TITAN feature table nor TCGA-Slide-Reports.csv supplied structured tumour content/cellularity, tissue area, artefact, biopsy-versus-resection status or slide/image-quality measurements. The field site_of_resection_or_biopsy is an anatomical-site variable and is no longer described as a specimen-procedure indicator. These quantities were therefore not used for exclusion or weighting. Generated narrative text was audited only as unvalidated same-image context: among {ival(pathology_qc.get('exact_report_matched_slides')):,} matched reports, tumour-content, tissue-area, artefact and explicit slide-quality phrases appeared in {ival(pathology_qc.get('tumour_content_mentions'))}, {ival(pathology_qc.get('tissue_area_mentions'))}, {ival(pathology_qc.get('artefact_mentions'))} and {ival(pathology_qc.get('slide_quality_mentions'))} slides, respectively. Mean pooling assigns each slide weight 1/n within a participant, after which every participant contributes one validation row; thus the 30-slide participant does not have 30-fold downstream weight. However, all 30 generated narratives for that participant, TCGA-DX-AB2L (SARC), mentioned no residual sarcoma/myxofibrosarcoma. We now highlight this as a clinically important inadequacy of barcode-only eligibility, not as an independently adjudicated exclusion. Methods, Results, Discussion, Supplementary Table S3b and four machine-readable pathology-QC files report the issue. The existing first-slide analysis remains a pooling-rule sensitivity, not a substitute for independent pathology review or tumour-area-aware aggregation."),
    ("Terminology: predictability",
     "Agreed. The Background now supplies one explicit operational definition used throughout: predictability means held-out cross-validated statistical association under the stated target, model, validation folds and performance threshold. Results that meet this criterion are no longer described as revealing biological information. The Results, tissue-source-site-code analysis, Discussion, limitations and Supplementary Methods state that such association does not establish causality or mechanism, directly recover the originating measurement, demonstrate analytical or clinical assay equivalence, or support omitting or replacing an assay. The reviewer report and repository documentation use the same definition."),
    ("Foundation-model ranking is conditional on the downstream probe",
     "Agreed and directly tested. Every title, abstract, Results, figure and conclusion statement now refers to the released representations under the specified PLS-based probe and avoids intrinsic foundation-model superiority language. Target-labelled patients and exact primary-atlas outer partitions were identical across TITAN, Giga-SSL and Prov-GigaPath; binary representation ranking used AUROC and continuous ranking used Q². The symmetric fixed 47-target ridge sensitivity retained the PLS-leading representation for 22/35 binary and 8/12 continuous targets. We then expanded the component range from 1-10 to 1-20 for all 366 union-positive or near-threshold binary pairs. The wider grid retained the primary leader for 323/366 pairs and changed 43. Across the complete 426-pair AUROC-centred primary atlas, at least one outer fit selected component 10 for 89 TITAN, 98 Giga-SSL and 126 Prov-GigaPath tasks, corresponding to 119, 137 and 169 of 2,130 outer fits. Component 20 was selected in 45, 57 and 51 of 1,830 expanded-grid outer fits. No numerical failure or fallback occurred. A variance audit found five constant Giga-SSL dimensions and none in TITAN or Prov-GigaPath; no near-constant dimensions were found. The manuscript reports selected-component distributions, ceiling frequencies, variance handling and failure policy by representation. It also states that possible direct TCGA overlap in Giga-SSL development differs from the reported TITAN and Prov-GigaPath pretraining corpora. Supplementary Tables S15a-S15c and the machine-readable files contain the complete results."),
    ("Tissue-source-site grouping demonstrates sensitivity but not confounding",
     f"Agreed. We now consistently describe this as sensitivity to TCGA tissue-source-site-code-grouped partitioning and explicitly state that neither attenuation nor code classification establishes confounding. We removed ‘strengthens the confounding concern’, ‘robust biological signals’ and equivalent causal language. Four additional internal controls were run for all {titan_candidate_total} TITAN candidates. Matched random outer partitions reproduced every grouped fold's test size and reproduced positive/negative counts exactly for all {len(site_b)} binary models. The median grouped-minus-matched-random change was {fnum(site_control_by_type.get('binary', {}).get('median_grouped_minus_matched'), 3)} balanced-accuracy units for binary models and {fnum(site_control_by_type.get('continuous', {}).get('median_grouped_minus_matched'), 3)} Q² for continuous models. Selection-conditioned paired patient-resampling intervals included zero for {ival(site_control_by_type.get('binary', {}).get('intervals_include_zero'))}/{len(site_b)} binary and {ival(site_control_by_type.get('continuous', {}).get('intervals_include_zero'))}/{len(site_c)} continuous models; {ival(site_control_by_type.get('binary', {}).get('intervals_below_zero'))} and {ival(site_control_by_type.get('continuous', {}).get('intervals_below_zero'))} intervals, respectively, lay wholly below zero. Code-only cross-validation and code-specific outcome heterogeneity were also reported for every endpoint. COAD–APC remained sensitive after exact class-count matching (balanced accuracy {fnum(site_control_apc.get(('COAD', 'APC'), {}).get('matched_random_metric'), 3)} matched random versus {fnum(site_control_apc.get(('COAD', 'APC'), {}).get('grouped_metric'), 3)} grouped; Δ {fnum(site_control_apc.get(('COAD', 'APC'), {}).get('grouped_minus_matched'), 3)}, 95% paired interval {fnum(site_control_apc.get(('COAD', 'APC'), {}).get('paired_ci_low'), 3)} to {fnum(site_control_apc.get(('COAD', 'APC'), {}).get('paired_ci_high'), 3)}), as did READ–APC ({fnum(site_control_apc.get(('READ', 'APC'), {}).get('matched_random_metric'), 3)} versus {fnum(site_control_apc.get(('READ', 'APC'), {}).get('grouped_metric'), 3)}; Δ {fnum(site_control_apc.get(('READ', 'APC'), {}).get('grouped_minus_matched'), 3)}, {fnum(site_control_apc.get(('READ', 'APC'), {}).get('paired_ci_low'), 3)} to {fnum(site_control_apc.get(('READ', 'APC'), {}).get('paired_ci_high'), 3)}). Code alone yielded AUROC {fnum(site_control_apc.get(('COAD', 'APC'), {}).get('code_only_metric'), 3)} and {fnum(site_control_apc.get(('READ', 'APC'), {}).get('code_only_metric'), 3)} for these endpoints. Among codes with at least five patients, APC prevalence ranged from {fnum(site_control_apc.get(('COAD', 'APC'), {}).get('minimum_prevalence_minimum5'), 3)} to {fnum(site_control_apc.get(('COAD', 'APC'), {}).get('maximum_prevalence_minimum5'), 3)} in COAD and {fnum(site_control_apc.get(('READ', 'APC'), {}).get('minimum_prevalence_minimum5'), 3)} to {fnum(site_control_apc.get(('READ', 'APC'), {}).get('maximum_prevalence_minimum5'), 3)} in READ. These results show code-associated outcome heterogeneity and attenuation beyond fold size or binary class count for the two APC examples, but they cannot distinguish technical acquisition from biological case mix, subtype, ancestry, referral or other code-associated structure. Methods explain why fixed-effect residualisation was not treated as primary evidence: a held-out code has no estimable training-set code effect and residualisation changes the grouped-validation estimand. Main Results, Discussion, Supplementary Table S10d2, two machine-readable tables and the pipeline now report the controls and their limitations."),
    ("Clarify the chronology and meaning of ‘prespecified’",
     "Agreed. We corrected this terminology throughout. The Abstract now says 'matched benchmark using fixed analysis settings' and identifies the study as retrospective. The study was not prospectively registered, and the initial repository commit bb0ccb8d016072519913d8a78e0157b9f2e09c5f dated 15 August 2026 contains both the TITAN analysis plan and completed screening results. We therefore describe its thresholds, eligibility limits, component range and local FDR scheme as 'documented analysis rules in the initial repository snapshot'; Git history cannot establish that they preceded outcome inspection. The matched three-representation comparison, PLS-versus-ridge probe sensitivity, 1-20-component sensitivity, matched-partition controls and five-partition fold/threshold-stability audit are explicitly labelled retrospective analyses. For the latter, the 560-task inclusion rule, repeat count and threshold grids were fixed in code before its alternative-partition results were inspected, but it remains unregistered and code plus results belong to the same working-tree revision. Supplementary Table S1a and analysis_chronology.csv report this chronology. 'Locked before analysis' is reserved for the eight-target permutation refinement, whose registry was committed at ac30ccb1fa4557e1e63d9a69f342361fcf36d7e3 before result commit 47fa5b9dbdfa4fe0d813d4306b028af57369dd4a; 'prospectively locked' is reserved for the future external-validation protocol committed at 0c17d4547d67009f3d007b97955be23db286fed8 before any external analysis. The Declaration no longer claims that a locked executable plan exists for the main study; it now states that the repository contains documented rules and chronology but cannot establish prospective locking."),
    ("The manuscript and supplement appear to be from different project versions",
     "Agreed. We treated this as a release-integrity failure and regenerated the manuscript, supplement, figures and reviewer response from one current build. The software name is now PathoFMPred throughout the article, supplement, analysis scripts and documentation; the interface validates 768-dimensional TITAN, 512-dimensional Giga-SSL or 768-dimensional Prov-GigaPath schemas according to the explicit foundation_model selection. We restored the omitted tissue-source-site metadata join before document generation and added a hard build failure if highlighted rows lack the grouped metric, delta, code count, robustness status or inner-fold grouping audit. Supplementary Table S6a now contains actual grouped estimates rather than empty placeholders. Figure 1 now shows all three representations; Figures 3 and 4 and their captions both state 12 displayed models; binary PR-AUC references point to Table S8; Figure 6 points to the new complete cancer-level Table S1b; all main tables are numbered and captioned; the COAD graphic and text use PathoFMPred and Figure 8 consistently; and Supplementary Figures are numbered in their order of appearance as S1–S6. The TRIPOD+AI map was cross-checked against the final table numbers. A source-level consistency audit now runs before document delivery."),
    ("9. The software-resource claim needs a clearer access and licensing model",
     f"Agreed. We now separate source-code, fitted-object and upstream terms explicitly. The public analysis source remains GPL-3.0-or-later, while contributor-authored PathoFMPred source code and documentation are public under MIT. The public package contains a minimal Giga-SSL fixture and offers checksum-verified, user-invoked downloads of the full Giga-SSL and Prov-GigaPath collections. Those fitted assets are distributed separately from the MIT source and carry CC BY 4.0 terms to the extent that the PathoFMPred authors hold rights, without replacing upstream Giga-SSL, Prov-GigaPath, embedding-dataset, TCGA or endpoint-source conditions. The TITAN collection is excluded from the public repository and remains in the private collaboration repository pending written redistribution permission. The registry contains {registry_object_total} representation-specific coefficient objects: {inventory_by_representation['TITAN']} TITAN, {inventory_by_representation['GigaSSL']} Giga-SSL and {inventory_by_representation['ProvGigaPath']} Prov-GigaPath. These counts are not matched crossing counts because the two alternative inventories use the same TITAN-qualified matched-eligible target universe. Selecting foundation_model changes both schema and coefficients when an object exists, but the registry does not cover every representation-specific crossing. The package licence, model-access notice and release notes state these boundaries and make clear that this is an access-policy statement rather than a legal determination."),
    ("10. The comparative results need to become more translationally interpretable",
     f"Agreed. We now report cross-representation threshold patterns as descriptive navigation fields and base the main comparison on Q²/AUROC, paired effects, partition stability and grouped-minus-matched-random changes. Every one of the {foundation_union_counts['tasks']} tasks crossing in at least one representation entered the three-representation grouped audit. Of {len(foundation_tss_grouped):,} representation-task fits, {len(foundation_tss_feasible_rows):,} were estimable; the ACC genome-doubling task failed for all three representations because a grouped inner training partition contained one class. Complete retention of every original crossing occurred for {foundation_tss_consensus_counts[('continuous', 'all three', 'complete retention')]}/{foundation_all_three_counts['continuous']} continuous and {foundation_tss_consensus_counts[('binary', 'all three', 'complete retention')]}/{foundation_all_three_counts['binary']} binary all-three tasks, so consensus is not presented as cohort-structure robustness. Machine-readable files provide all 1,933 targets, {len(foundation_tss_grouped):,} grouped representation-task records, task-, outer-fold- and inner-fold adequacy fields and the deterministic main-table selection. PathoFMPred exposes threshold status, code count, realized folds, grouped effect, matched-random comparator and sparse-fold warning separately rather than assigning a clinical or validated evidence grade."),
    ("11. Continuous endpoints need a reliability analysis analogous to the binary class-size audit",
     "Agreed. We added a revision-specific reliability audit for all 219 continuous TITAN candidates. Their labelled sample sizes ranged from 61 to 1,051 (median 371; interquartile range 233.5–468), and 13 had fewer than 100 patients. Compared with the 206 larger models, this limited group had lower median repeat-prediction Spearman stability (0.892 versus 0.936) and greater median across-repeat Q² standard deviation (0.054 versus 0.017), although sample size had little monotonic relationship with mean Q² (Spearman ρ=0.060). It had a moderate relationship with prediction stability (ρ=0.367). We persisted all 5,475 selected-component decisions: 36 (0.7%) reached the ten-component ceiling, involving 18/219 models; within the limited group, 3/325 fits and 2/13 models reached it. Supplementary Table S10h reports sample-size bands and all 13 limited models, while Figure S5 displays Q² and repeat stability versus sample size and the smaller-model component distributions. The complete machine-readable audit contains model-, band- and fold-level results. The <100-patient category is explicitly described as a revision-added descriptive evidence warning, not a clinical or inferential boundary. These 13 models remain in the complete atlas but are excluded from default PathoFMPred inference; the registry and inference output expose sample size, Q² variability, repeat stability, component range and ceiling metadata, and explicit opt-in emits a warning."),
    ("12. The literature audit requires methods, and the Discussion should be substantially shortened",
     "Agreed. We now describe the mutation comparison as a targeted narrative cross-check rather than a comprehensive audit. The Methods and Supplement report PubMed as the searched database, the last search date (24 August 2026), four reproducible search strings, backward/forward citation checking, inclusion and exclusion criteria, treatment of preprints, extraction fields and the absence of duplicate screening or formal risk-of-bias assessment. Pooled colorectal evidence is mapped to both COAD and READ only when explicitly labelled ‘pooled colorectal’, while exact-cancer evidence takes precedence. The complete method is released as data/reference/literature_crosscheck_method.csv, and ‘not identified’ is explicitly limited to the reviewed search rather than presented as bibliographic novelty. We also rebuilt the Discussion around five short sections: three-model consensus and discordance; sensitivity to TCGA tissue-source-site-code partitioning; downstream-probe dependence; the translational role of PathoFMPred; and one consolidated limitations paragraph. Detailed external-performance examples, the extended mutation crosswalk, multi-outcome PLS, morphology examples, future-protocol mechanics and operational metadata remain in the Supplement or software documentation rather than interrupting the main interpretation."),
    ("Editorial and presentation comments 1–18",
     "Addressed with two author-dependent exceptions. (1) The title now begins ‘Patient-level benchmarking’. (2) The Abstract defines Q²≥0.20 and balanced accuracy≥0.60, calls the counts effect-threshold crossings and describes the revision-added comparison as a ‘matched benchmark using fixed analysis settings’. (3) The comparison tables are numbered and titled; Table 2 reports both available and common-cohort patient counts, while Table 3 reports pretraining/evaluation overlap instead of a uniformly empty external-validation column. (4) The three-model comparison is Figure 2 immediately after the matched Results; at the authors' request, the post hoc COAD software illustration remains main Figure 8. (5) Both panels of Figure 5 now use the largest five-repeat mean outcome-specific metric. (6) The standardized LDA-score zero line was removed and the axis states that no common classification threshold exists on that scale. (7) Figure 8 is now restricted to the two simplified radar panels with original prediction values at every corner; binary details remain in the separate case reports. (8) Display terminology is standardized to Giga-SSL, Prov-GigaPath and PathoFMPred; matched results are called cancer–endpoint pairs and effect-threshold crossings. Internal API identifiers such as GigaSSL remain unchanged where exact software syntax is required. (9) TSS, SC interval, OOF and q-value are defined at first use or in the abbreviation list. (10) A navigational contents section was added to the Supplement, and repeated release-policy language is consolidated in notes while complete records remain in synchronized machine-readable companions. (11) ‘Authoritative CSV’ wording was removed in favour of ‘synchronized complete-resolution companion’. (12) References 17 and 18 are now cited in the PLS Methods; references 31 and 33 are cited in Background and data-linkage Methods. PubMed confirms that the unusual spelling Angela Lamrca in reference 35 is correct. (13) Methods report removal of 1,406 exact duplicate Prov-GigaPath rows. (14) Table S6c now identifies its internal metrics as five-repeat mean nested-CV estimates on the full outcome-labelled TITAN cohort plus the separate tissue-source-site-code-grouped sensitivity, and distinguishes these from primary-screen and apparent full-data performance. (15) Funding, competing interests and CRediT contributions still require author-supplied facts and remain explicitly flagged rather than invented; docs/SUBMISSION_ACTIONS.md lists them. (16) The duplicate Methods AI statement was removed; one disclosure remains in Acknowledgements. (17) A release/DOI must be minted from the final synchronized commit after author approval. The manuscript no longer claims that the current dirty working tree is an archival release, and the required release steps are documented. (18) Supplementary Figures S1–S6 occur and are cited sequentially."),
    ("Final editorial comments 1–18",
     "Addressed, with the submission declarations and archival identifiers still requiring author action. (1) The title is now exactly ‘Patient-level comparison of three released pathology embedding pipelines with a common PLS-based probe across 32 TCGA cancers.’ (2) The Abstract states that the patient was the unit of analysis and cross-validation. (3) Methods give the exact artifact-access, identifier, fixed-vector, common-coverage and distinct-strategy inclusion criteria and clarify that the set is pragmatic rather than exhaustive. (4) Inner component selection pools five-fold held-out predictions, minimises RMSD for continuous outcomes, maximises balanced accuracy for binary outcomes and resolves exact ties toward the smallest component count. (5) The first screening-statistic definition now states that 2×BA−1≥0.20 is exactly BA≥0.60 and that 0.40 corresponds to BA≥0.70. (6) Table 2 reports n/N and percentages against 1,507 continuous and 426 binary tasks. (7) Table 5 now distinguishes the paired all-three examples deterministically: largest TITAN effect versus largest mean alternative-representation effect. (8) Display terminology is standardised to Giga-SSL, Prov-GigaPath and TCGA tissue-source-site code; compact internal identifiers are retained only where they are exact software or file fields. (9) The duplicated PathoFMPred wording was corrected. (10) Methods explain that the five constant Giga-SSL dimensions preserve the released schema and become zero after training-fold centering, so they cannot affect covariance, effective rank or component counts; no numerical fallback occurred. (11) The 1,406 excess Prov-GigaPath rows arose as repeated filename records already present in the downloaded Parquet; its dataset card does not document their cause. They represented 1,402 slide identifiers, had exactly identical final-layer vectors and were removed before slide filtering and patient pooling, preventing altered patient weights. (12) Figure 4 labels now show balanced accuracy, AUROC, PR-AUC and prevalence, and Figure 5B states PR-AUC with its prevalence no-skill reference. (13) Figure 5B is explicitly a score-distribution illustration, not calibration or a common decision boundary. (14) Additional file 1 is consistently inventoried as Tables S1–S18 and Figures S1–S6. (15) Competing interests, funding, author contributions, the final release tag, immutable synchronized commit and DOI remain author-dependent blockers and are visibly flagged rather than invented. (16) Additional files 2 and 3 are included in the review package and validated as PDFs. (17) The bibliography and repository metadata were re-audited against the primary DOI, PubMed, GitHub and Hugging Face records; the unusual author spelling Lamrca is confirmed by the publication record, and access dates were updated to 24 August 2026. (18) The main subgroup paragraph is now limited to denominators and the absence of a fairness conclusion; exact results and non-estimability reasons remain in the Supplement."),
    ("The study compares released embedding pipelines, not isolated foundation-model quality",
     f"Agreed. The title now refers explicitly to ‘three released pathology embedding pipelines with a common PLS-based probe’; the Abstract, Background, Methods, Results, Figure 2, Table 3, Supplement and Conclusions consistently define the estimand as differences among complete released embedding pipelines under that probe. This includes upstream preprocessing, physical-resolution assumptions, representation-learning exposure, encoder architecture and released layer; these factors were not harmonised, so the manuscript makes no intrinsic foundation-model-quality claim. We state prominently that Giga-SSL development used TCGA and direct image overlap cannot be excluded. Its nested cross-validation therefore withholds downstream molecular labels but does not necessarily evaluate slides unseen during representation learning; this is distinguished from supervised label leakage and from the reported TCGA-excluded pretraining corpora of TITAN and Prov-GigaPath. Methods retain five explicit inclusion criteria: accessible precomputed slide-level TCGA vectors, deterministic slide identifiers, fixed-length embeddings, adequate 32-cancer common-cohort coverage and a distinct published whole-slide strategy without pixel reprocessing. New Supplementary Table S15e and foundation_model_exclusion_inventory.csv provide a representative inventory of UNI/UNI2-h, CONCH, Virchow, H-optimus, CHIEF, PRISM and Threads and the criterion preventing inclusion; exclusion is explicitly not a quality judgement. New Supplementary Table S15f and titan_provgigapath_paired_summary.csv isolate the existing paired TITAN–Prov-GigaPath results without refitting. TITAN had the higher effect for {ival(titan_prov_paired_by_outcome['continuous']['TITAN_higher_effect']):,}/1,507 continuous and {ival(titan_prov_paired_by_outcome['binary']['TITAN_higher_effect']):,}/426 binary pairs, compared with {ival(titan_prov_paired_by_outcome['continuous']['ProvGigaPath_higher_effect']):,} and {ival(titan_prov_paired_by_outcome['binary']['ProvGigaPath_higher_effect']):,} for Prov-GigaPath; both crossed the descriptive threshold in {ival(titan_prov_paired_by_outcome['continuous']['both_effect_threshold_crossing']):,} continuous and {ival(titan_prov_paired_by_outcome['binary']['both_effect_threshold_crossing']):,} binary pairs. Median Prov-GigaPath-minus-TITAN effects were {fnum(titan_prov_paired_by_outcome['continuous']['median_delta_ProvGigaPath_minus_TITAN'], 3)} Q² and {fnum(titan_prov_paired_by_outcome['binary']['median_delta_ProvGigaPath_minus_TITAN'], 3)} AUROC. We describe this as reducing one known difference in reported pretraining exposure, not as external validation or an architecture-only comparison."),
    ("5. The central three-representation atlas needs fold-assignment and threshold stability analysis",
     f"Agreed. We selected every primary effect-threshold-crossing cancer-endpoint pair plus every pair lying within 0.05 of Q²=0.20 or AUROC=0.60 for at least one representation. The set comprised {len(foundation_fold_selection)} unique tasks. Each task was rerun on five new nested partitions with identical outcome-labelled patients, folds, seeds, component range and tuning rules across TITAN, Giga-SSL and Prov-GigaPath. The primary all-three class persisted in all five partitions for {consensus_class_stability('continuous', ['all three'])[0]}/{consensus_class_stability('continuous', ['all three'])[1]} continuous and {consensus_class_stability('binary', ['all three'])[0]}/{consensus_class_stability('binary', ['all three'])[1]} binary pairs. The primary leading representation was unchanged in all five partitions for {winner_stability('continuous')['all_five']}/{winner_stability('continuous')['tasks']} continuous and {winner_stability('binary')['all_five']}/{winner_stability('binary')['tasks']} binary pairs. We report repeat crossing proportions, paired Q²/AUROC effects, variability and ranks rather than relying on a single categorical label. These are internal fold-assignment sensitivities, not external validation or representation-specific permutation/FDR results."),
    ("Tissue-source-site-code sensitivity should be integrated into the main evidence hierarchy",
     f"Agreed and addressed with a matched analysis rather than extrapolating the previous TITAN-only sensitivity. All {foundation_union_counts['tasks']} cancer-endpoint pairs crossing in at least one representation were rerun for TITAN, Giga-SSL and Prov-GigaPath with complete two-character TCGA tissue-source-site codes held apart in outer and inner validation. Identical patients, outcomes, grouped folds, seeds and tuning rules were used across representations. Of {len(foundation_tss_grouped):,} representation-task fits, {len(foundation_tss_feasible_rows):,} were estimable; ACC genome doubling failed for all three because one grouped inner training partition contained a single class. The original threshold was retained for {foundation_tss_retention('TITAN', 'continuous')[0]}/{foundation_tss_retention('TITAN', 'continuous')[1]} TITAN, {foundation_tss_retention('GigaSSL', 'continuous')[0]}/{foundation_tss_retention('GigaSSL', 'continuous')[1]} Giga-SSL and {foundation_tss_retention('ProvGigaPath', 'continuous')[0]}/{foundation_tss_retention('ProvGigaPath', 'continuous')[1]} Prov-GigaPath continuous crossings; binary retention was {foundation_tss_retention('TITAN', 'binary')[0]}/{foundation_tss_retention('TITAN', 'binary')[1]}, {foundation_tss_retention('GigaSSL', 'binary')[0]}/{foundation_tss_retention('GigaSSL', 'binary')[1]} and {foundation_tss_retention('ProvGigaPath', 'binary')[0]}/{foundation_tss_retention('ProvGigaPath', 'binary')[1]}. Main Figure 3 and Table 3 report grouped and matched-random effects together. Supplementary Tables S15h and S15k and the synchronized machine-readable files provide representation-level estimates, fold audits, code counts, single-class indicators and sparse-fold warnings. Tissue-source-site code is not an institution, scanner or laboratory identifier; attenuation is sensitivity to a grouped partition, not proof of confounding, and multi-representation consensus is not evidence of external transportability."),
    ("7. Raw crossing counts overstate breadth because endpoint families are highly unbalanced and correlated",
     "Agreed. We no longer lead with raw crossing counts. Figure 2A and main Table 2 now report four catalogue-normalized measures for each representation and outcome type: task crossing percentage, unique endpoint-definition coverage, the unweighted macro-average of within-family crossing rates and the unweighted macro-average of within-cancer crossing rates. The matched atlas contains 187 unique endpoint definitions (56 continuous and 131 binary), whereas the complete 2,073-task TITAN universe contains 194; these denominators are stated in Methods, Results and Supplementary Table S17. TITAN crossed 13.8% of continuous and 21.8% of binary tasks, with unique-definition coverage of 40/56 (71.4%) and 36/131 (27.5%). Prov-GigaPath crossed 8.6% and 17.8%, with definition coverage of 34/56 (60.7%) and 29/131 (22.1%); Giga-SSL crossed 7.0% and 14.8%, with definition coverage of 29/56 (51.8%) and 25/131 (19.1%). Macro family rates were 7.6%/63.0%, 5.5%/43.0% and 2.9%/37.0%, and macro cancer rates were 13.6%/26.5%, 8.5%/25.4% and 6.9%/22.9%, respectively (continuous/binary; TITAN, Prov-GigaPath, Giga-SSL). We report explicitly that Thorsson-derived endpoints contributed 200/208 (96.2%) TITAN, 121/130 (93.1%) Prov-GigaPath and 102/105 (97.1%) Giga-SSL continuous crossings. Figure 2A now leads with normalized measures rather than totals. Supplementary Table S17 has been expanded to include normalized breadth, leading families and cancers, and exact endpoint definitions and broader programmes retained across the most cancers. Four new machine-readable companions provide the complete normalized summary and every retained cancer code. Throughout the Abstract, Results, Discussion, figure caption and table notes, raw crossings are now defined as correlated task-level breadth within this catalogue—not independent biological discoveries."),
    ("Direct genomic outcomes, inferred immune phenotypes and same-H&E targets should not be combined without parallel stratified summaries",
     "Agreed. We added an explicit provenance-stratified analysis rather than treating all labels as molecular assays. The 2,073-task endpoint dictionary contains 265 directly observed genomic alterations, 439 sequencing-derived continuous burdens, 685 computationally inferred immune-cell fractions, 299 transcriptomic signatures, 372 composite genomic-context outcomes and 13 pathology-associated same-H&E TIL Regional Fraction tasks. Of the 13 same-H&E tasks, 11 met common-cohort eligibility in the 1,933-task matched benchmark and all 11 crossed the documented threshold for every representation. Excluding them changed continuous crossings from 208/1,507 to 197/1,496 for TITAN, 130/1,507 to 119/1,496 for Prov-GigaPath and 105/1,507 to 94/1,496 for Giga-SSL; total matched crossings changed from 301/1,933 to 290/1,922, 206/1,933 to 195/1,922 and 168/1,933 to 157/1,922, respectively. Main Table 2 now has a provenance panel separating direct genomic alterations, sequencing-derived burdens, inferred immune-cell fractions, transcriptomic signatures, composite scores and same-H&E quantities. Supplementary Table S18 supplies every representation-by-class denominator, the exclusion sensitivity and leading mature all-three examples with complete grouped retention; three synchronized CSV companions retain full resolution. The Methods and Results now state that CIBERSORT fractions, methylation-derived leukocyte fractions and RNA signatures estimate agreement with another computational phenotype, not recovery of directly measured immune-cell abundance, and the same-H&E TIL fraction is described as concordance rather than cross-modal prediction. The Discussion now distinguishes direct sequence-based examples (THYM–GTF2I and LGG–TP53 mutations) from computational or derived examples (COAD strict MSI, TGCT TGF-beta response and methylation-derived leukocyte fraction), reports their three-representation and grouped effects, and explicitly excludes BLCA TIL Regional Fraction from cross-modal interpretation."),
    ("9. Molecular–slide linkage and within-patient heterogeneity",
     f"Agreed. We added a patient-by-source linkage audit using the 15-character TCGA sample barcode. Same-sample concordance is now reported separately for Taylor aneuploidy, Sanchez-Vega pathway, Gao fusion, cBioPortal MSI and MC3 mutation resources; Thorsson supplies only participant identifiers, so its {ival(linkage_by_source.get('Thorsson2018_PanImmune_MS', {}).get('covered_patients')):,} covered patients are explicitly labelled participant-linked and exact specimen concordance is not estimable. The Methods, Results and Supplementary Table S3c state that even an exact sample barcode does not establish the same portion, analyte, aliquot, block, tumour region or subclone. We also added numerical slide heterogeneity for TITAN, Giga-SSL and Prov-GigaPath: patient-level pairwise cosine dispersion, slide-to-centroid dispersion, mean-versus-median centroid distance and maximum leave-one-slide-out centroid change. Every TITAN candidate was refitted after coordinate-wise median pooling with identical patients, seeds, rSVD settings and nested-CV rules. Mean-versus-median results were highly concordant (Spearman {fnum(median_pool_by_type.get('continuous', {}).get('correlation_with_mean'))} continuous and {fnum(median_pool_by_type.get('binary', {}).get('correlation_with_mean'))} binary), retaining the original threshold for {ival(median_pool_by_type.get('continuous', {}).get('retained_original_effect_threshold'))}/219 and {ival(median_pool_by_type.get('binary', {}).get('retained_original_effect_threshold'))}/104 models. Finally, TCGA-DX-AB2L was removed before fold construction and all 20 SARC candidates were refitted: 13/15 continuous and 4/5 binary candidates retained the threshold. The three changes are named in the endpoint-level files. We continue to treat the generated slide narratives as same-image context rather than adjudicated pathology, and we do not claim that numerical pooling sensitivity replaces tumour-content or image-quality review."),
]
responses.append((
    "10. Limited-evidence models and multiplicity procedure",
    "Agreed. We added an executable row-level denominator audit and regenerated the manuscript, supplement and response from its outputs. Of 1,614 eligible continuous tests, 1,393 fell below Q²=0.20 and were not permuted; each was assigned raw p=1. The remaining 221 completed 999 permutations. Of 459 eligible binary tests, 352 fell below balanced accuracy=0.60 and were not permuted; each was assigned raw p=1. Of the 107 checkpoint-passing binary tests, 104 completed 999 permutations and three entered permutation testing but were conservatively early-stopped after 49 exceedances and separately assigned raw p=1. Every eligible row—including both distinct p=1 categories—remained in every applicable BH denominator. The audit records local denominators of 1–50 continuous and 1–48 binary tests, across-cancer/family denominators of 30–1,434 and 3–238, outcome-wide denominators of 1,614 and 459, and the atlas-wide denominator of 2,073; recomputed q-values match the saved results exactly. Main Methods and Results, Supplementary Table S10f and three new machine-readable files now expose these facts directly. We also report inclusive and standard-evidence counts in parallel. In the matched atlas, continuous standard-evidence crossings were 196/208 for TITAN, 125/130 for Prov-GigaPath and 103/105 for Giga-SSL; binary counts were 77/93, 60/76 and 51/63. The standard denominators were 1,185 continuous tasks with n≥100 and 223 binary tasks with at least 50 patients per class. In the separately permutation/FDR-qualified TITAN layer, 206/219 continuous and 87/104 binary candidates met these descriptors. The abstract, main Table 2, Results and new Supplementary Table S15i now show these counts; limited-evidence models remain visible in the inclusive atlas but are excluded from default inference and from unqualified headline examples. We state explicitly that the ≥100 and ≥50-per-class rules are revision-added evidence-maturity descriptors, not retrospective significance filters, and do not alter eligibility, raw p-values, q-values or the complete atlas."
))
responses.append((
    "11. The fitted-model inventory does not reconcile clearly with the reported crossing counts",
    f"Agreed. The identical 297-object counts were not representation-specific crossing inventories. Both Giga-SSL and Prov-GigaPath were fitted on the same 297 targets inherited from the permutation/FDR-qualified TITAN catalogue that remained eligible in the 8,241-patient matched cohort: 198 continuous and 99 binary targets. This shared-universe design avoided selecting objects after inspecting each alternative representation's performance, but it meant that object presence and matched effect-threshold crossing were different facts. Giga-SSL objects cover {inventory_reconciliation_value('GigaSSL', 'continuous', 'representation_crossings_with_controlled_object')}/105 continuous and {inventory_reconciliation_value('GigaSSL', 'binary', 'representation_crossings_with_controlled_object')}/63 binary crossings; 12 continuous and 13 binary Giga-SSL crossings have no fitted object. Prov-GigaPath objects cover {inventory_reconciliation_value('ProvGigaPath', 'continuous', 'representation_crossings_with_controlled_object')}/130 and {inventory_reconciliation_value('ProvGigaPath', 'binary', 'representation_crossings_with_controlled_object')}/76; 18 and 15 crossings, respectively, have no fitted object. Conversely, 105 continuous and 49 binary Giga-SSL objects and 86 continuous and 38 binary Prov-GigaPath objects did not cross for that representation. The TITAN registry separately contains all 323 candidates from the larger TITAN-only permutation/FDR-qualified layer and is therefore also not numerically identical to its common-cohort matched crossings. We added a target-level executable audit and two machine-readable files, fitted_model_inventory_reconciliation.csv and fitted_model_target_universe_audit.csv. Supplementary Table S6d now shows crossings, objects, below-threshold objects, uncovered crossings and coverage percentages side by side. Every registry row now records the fitted-object target universe, matched representation-specific crossing status, coverage note and the fact that the inventory is incomplete. compare_pathofm_models() was corrected so that it never infers consensus from object count: it reports object availability, matched-threshold status, selection basis and partial resource scope separately, and explains that absence of an object does not imply an untested or negative atlas task. The manuscript does not describe PathoFMPred as a complete operationalization of the multi-representation atlas. The public MIT-licensed package includes a minimal Giga-SSL fixture and checksum-verified, user-invoked downloads of the Giga-SSL and Prov-GigaPath collections under separate asset notices. The TITAN collection remains only in the private collaboration repository pending written redistribution permission. The final archived release, immutable synchronized commit and DOI remain explicit author-dependent blockers before acceptance and were not invented for this working tree."
))
responses.append((
    "12. The main text needs a stronger translational synthesis and a more effective figure hierarchy",
    "Agreed. We reorganized the main narrative around four internal priorities: (1) larger-sample all-three associations with complete TCGA tissue-source-site-code retention; (2) larger-sample two-representation associations with complete grouped retention; (3) representation-specific associations that would also need probe and alternative-partition stability; and (4) signals that collapse under grouped partitioning or depend strongly on the downstream probe. The revised Discussion names THYM-GTF2I, THCA-BRAF, LGG-IDH1/TP53 and COAD strict MSI as direct or sequence-derived high-priority examples, then separately interprets TGCT TGF-beta response, TGCT leukocyte fraction and LIHC wound healing as agreement with derived transcriptomic or methylation phenotypes rather than direct immune-cell measurements. It explicitly states that no representation-specific signal was promoted to the highest translational tier. The main figure sequence now mirrors the primary benchmark, while Supplementary Figure S4 carries the deeper TITAN cohort-structure analysis, Tables S7 and S8 provide compact top-result summaries, and main Figure 4 preserves the author-requested COAD radar. Detailed chronology, software reconciliation and representation-specific licensing text remain in the Supplement. All figure, inventory and cross-reference changes were regenerated from the same build."
))
responses.append((
    "1. The matched three-representation benchmark should become the unmistakable central paper",
    "Agreed. The main Results were rebuilt around the matched cohort, tumour-feature yield, representation and partition sensitivity, and translational interpretation. TITAN-only tissue-source-site, continuous-atlas and binary-atlas details remain in compact Supplement tables and machine-readable companions. The two COAD patients are shown in main Figure 4 with genuine PathoFMPred outputs from TITAN, Giga-SSL and Prov-GigaPath inputs for the same six continuous endpoints; the machine-readable CSV gives every original value and model field. PathoFMPred is presented as a research-interface demonstration and not as additional performance evidence."
))
responses.append((
    "2. ‘Revision-added’ is not appropriate reader-facing scientific terminology",
    "Agreed. We removed ‘revision-added’ from the Abstract, scientific Methods, Results headings and text, Discussion, Conclusions, tables and figure captions. The primary study is now described as a ‘retrospective matched benchmark conducted with documented analysis settings.’ The supporting TITAN analysis is now called the ‘permutation/FDR-filtered internal TITAN screen,’ avoiding language that could imply confirmatory status. The detailed chronology is confined to Supplementary Table S1a and the machine-readable audit trail. ‘Prospectively locked’ is retained only for future external-evaluation targets supported by the cited separate pre-result protocol commit. No analysis of the present TCGA benchmark is described as prospectively locked or confirmatory."
))
responses.append((
    "1. Align the binary tuning objective, primary metric and crossing rule",
    f"Agreed. We adopted the requested AUROC-centred benchmark and regenerated the complete matched binary layer. For every one of the 426 binary cancer-endpoint pairs and each representation, pooled inner out-of-fold AUROC selects the 1-10-component model, outer out-of-fold AUROC is the primary paired statistic, and AUROC at least 0.60 defines the descriptive crossing. A balanced-accuracy-maximising threshold learned only from inner training predictions supplies balanced accuracy, sensitivity, specificity, PPV and NPV. PR-AUC is reported with the observed TCGA prevalence as its no-skill reference. The regenerated binary crossing counts are {foundation_crossings('TITAN', 'binary')}/{foundation_crossings('GigaSSL', 'binary')}/{foundation_crossings('ProvGigaPath', 'binary')} for TITAN/Giga-SSL/Prov-GigaPath. We regenerated consensus labels, alternative-partition stability, tissue-source-site-code-grouped retention, highlighted tables, out-of-fold predictions and the controlled registry from this definition. We also compared empirical-training-prior, equal-prior and training-only optimized calls on the identical AUROC-selected outer scores. Balanced-accuracy crossings under those three rules were {ival(binary_operating_value('TITAN', 'empirical training priors', 'ba_crossings_for_sensitivity'))}/{ival(binary_operating_value('TITAN', 'equal class priors', 'ba_crossings_for_sensitivity'))}/{ival(binary_operating_value('TITAN', 'training-only optimized threshold', 'ba_crossings_for_sensitivity'))} for TITAN, {ival(binary_operating_value('GigaSSL', 'empirical training priors', 'ba_crossings_for_sensitivity'))}/{ival(binary_operating_value('GigaSSL', 'equal class priors', 'ba_crossings_for_sensitivity'))}/{ival(binary_operating_value('GigaSSL', 'training-only optimized threshold', 'ba_crossings_for_sensitivity'))} for Giga-SSL and {ival(binary_operating_value('ProvGigaPath', 'empirical training priors', 'ba_crossings_for_sensitivity'))}/{ival(binary_operating_value('ProvGigaPath', 'equal class priors', 'ba_crossings_for_sensitivity'))}/{ival(binary_operating_value('ProvGigaPath', 'training-only optimized threshold', 'ba_crossings_for_sensitivity'))} for Prov-GigaPath. The companion table reports paired changes in balanced accuracy, sensitivity, specificity, PPV and NPV for all 1,278 representation-task rows; AUROC and PR-AUC remain unchanged across these three call rules because the selected component and continuous score are fixed. The former empirical-prior balanced-accuracy atlas is retained only as a historical sensitivity and no longer defines primary crossings or consensus. Supplementary Table S10j and the machine-readable target-, fold-, operating-rule- and patient-level companions report the full results."
))
responses.append((
    "4. Threshold crossings and R1–R4 classes should not dominate the scientific conclusions",
    f"Agreed. We removed R1–R4 from the Abstract, main Results tables, Discussion hierarchy and Conclusions. The composite remains only as a deprecated machine-registry navigation tag for backward compatibility; it no longer selects or ranks the main examples. We also replaced the prior reader-facing evidence-grade terminology with the descriptive ‘larger-sample stratum’ and ‘smaller-sample stratum’. The n≥100 continuous and ≥50-per-binary-class cut-offs are now stated explicitly as denominator descriptors, not evidence grades, significance filters or guarantees of stability. Main Figure 3 was replaced by a threshold-light analysis showing primary Q²/AUROC versus the median and interquartile range across five alternative matched partitions, tissue-source-site-code-grouped versus matched-random Q²/AUROC, and the proportion of alternative partitions retaining the primary leading-representation rank. The former category-only consensus graphic moved to Supplementary Figure S6 and is labelled as a navigation display. Main Table 4 now reports, for each translational example, primary Q²/AUROC, alternative-partition median and interquartile range, crossing proportion, winner-rank stability, grouped effect, grouped-minus-matched-random difference and sample-size stratum; it contains neither consensus tiers nor R1–R4. A new 1,680-row machine-readable companion, foundation_model_effect_partition_audit.csv, supplies these fields for every representation in the 560-pair stability set, and Supplementary Table S15j provides a compact summary. The Abstract and Conclusions now state that Q²≥0.20 and balanced accuracy≥0.60 are pragmatic catalogue-navigation thresholds rather than inferential boundaries. For context, the primary leading representation remained unchanged in all five alternative partitions for {winner_stability('continuous')['all_five']}/{winner_stability('continuous')['tasks']} continuous and {winner_stability('binary')['all_five']}/{winner_stability('binary')['tasks']} binary pairs, underscoring why continuous effects and rank stability—not a one-step threshold class—now drive interpretation."
))
responses.append((
    "2. Keep the central result probe-specific and resolve the component ceiling",
    f"Agreed. We retained the claim-narrowing language and extended the wider-component analysis far beyond the former 47-target subset. The title, Abstract, Methods, Results, Discussion and Conclusions now define the primary estimand as the comparison of three released embedding pipelines under one common 1-10-component PLS-based probe. The manuscript does not interpret the result as intrinsic foundation-model superiority or each pipeline's best achievable performance under an alternative head. We expanded the range to 1-20 components for all 366 binary pairs that crossed AUROC 0.60 in at least one representation or lay within 0.05 of that threshold. The analysis used the identical outer folds, pooled inner AUROC objective, rSVD seed schedule and training-only operating-threshold rule. It retained the leading representation for 323/366 pairs (88.3%) and changed 43. Representation-specific crossings changed from 237 to 230 for TITAN, 170 to 165 for Giga-SSL and 180 to 176 for Prov-GigaPath. Median AUROC changes were effectively zero, but maximum absolute target-level changes were {fnum(foundation_binary_component20_by_model['TITAN']['maximum_absolute_auroc_delta'], 3)}, {fnum(foundation_binary_component20_by_model['GigaSSL']['maximum_absolute_auroc_delta'], 3)} and {fnum(foundation_binary_component20_by_model['ProvGigaPath']['maximum_absolute_auroc_delta'], 3)}. In the complete 426-pair AUROC-centred primary atlas, at least one outer fit selected component 10 for 89 TITAN, 98 Giga-SSL and 126 Prov-GigaPath tasks; 119, 137 and 169 of 2,130 outer fits reached the ceiling. In the 366-pair expanded analysis, component 20 was selected in 45, 57 and 51 of 1,830 outer fits. All 5,490 expanded-grid outer fits completed with no numerical failure or fallback. The feature audit found no constant or near-constant TITAN or Prov-GigaPath dimensions and five constant Giga-SSL dimensions. We retained those dimensions to preserve the released schema; training-fold centering maps them to zero, so they contribute no covariance. For the cleaner paired pretraining-exposure comparison, TITAN and Prov-GigaPath AUROCs had Spearman correlations of {fnum(foundation_titan_prov_component20['primary_spearman'], 3)} and {fnum(foundation_titan_prov_component20['expanded_spearman'], 3)} under the 1-10 and 1-20 grids, and their pairwise leader changed for {ival(foundation_titan_prov_component20['pairwise_leader_changed'])}/366 pairs. The symmetric fixed 47-target ridge sensitivity remains separate and now retains the PLS-leading representation for {ival(probe_by_type['binary']['winner_retained'])}/{ival(probe_by_type['binary']['targets'])} binary and {ival(probe_by_type['continuous']['winner_retained'])}/{ival(probe_by_type['continuous']['targets'])} continuous pairs. Supplementary Tables S15a-S15c and eight machine-readable companions report every target, outer fit, selected-component distribution, feature audit, failure policy and paired result."
))
responses.append((
    "3. Treat the matched atlas as descriptive unless representation-specific inference is added",
    f"Agreed. We retained the matched atlas as a descriptive benchmark and did not add a post hoc representation-specific permutation/FDR analysis. The Abstract, Methods, Results, Table 1, Figure 2, Discussion and Conclusions now use 'effect-threshold crossing' for Q² at least 0.20 or AUROC at least 0.60. They do not call matched results positive, screen-positive or discoveries. The manuscript states prominently that 1,933 cancer-endpoint tasks represent 187 definitions repeated across cancers, include correlated phenotypes and yield catalogue-dependent counts rather than independent biological discoveries. Figure 2 now leads with the complete paired Q²/AUROC distributions for Giga-SSL and Prov-GigaPath relative to TITAN. The Results report their Spearman correlations and median paired effects before presenting any threshold summary. Main Table 1 gives eligible denominators, effect-threshold-crossing proportions and unique definition counts by tumour-feature class. The same subsection reports task-level, unique-definition, macro-family and macro-cancer percentages for each representation and outcome type. Thorsson-derived labels are identified as contributing 200/208 TITAN, 102/105 Giga-SSL and 121/130 Prov-GigaPath continuous effect-threshold crossings. For all {len(foundation_fold_selection)} effect-threshold-crossing or near-threshold pairs, we now report five-partition effect-threshold-crossing frequencies and paired effect variability. An effect-threshold crossing recurred in all five partitions for {foundation_crossing_stability_by_key[('TITAN', 'continuous')]['all_five']}/{foundation_crossing_stability_by_key[('TITAN', 'continuous')]['tasks']}, {foundation_crossing_stability_by_key[('GigaSSL', 'continuous')]['all_five']}/{foundation_crossing_stability_by_key[('GigaSSL', 'continuous')]['tasks']} and {foundation_crossing_stability_by_key[('ProvGigaPath', 'continuous')]['all_five']}/{foundation_crossing_stability_by_key[('ProvGigaPath', 'continuous')]['tasks']} continuous pairs and {foundation_crossing_stability_by_key[('TITAN', 'binary')]['all_five']}/{foundation_crossing_stability_by_key[('TITAN', 'binary')]['tasks']}, {foundation_crossing_stability_by_key[('GigaSSL', 'binary')]['all_five']}/{foundation_crossing_stability_by_key[('GigaSSL', 'binary')]['tasks']} and {foundation_crossing_stability_by_key[('ProvGigaPath', 'binary')]['all_five']}/{foundation_crossing_stability_by_key[('ProvGigaPath', 'binary')]['tasks']} binary pairs for TITAN, Giga-SSL and Prov-GigaPath. Median between-partition standard deviations were {fnum(foundation_crossing_stability_by_key[('TITAN', 'continuous')]['median_effect_sd'])}/{fnum(foundation_crossing_stability_by_key[('GigaSSL', 'continuous')]['median_effect_sd'])}/{fnum(foundation_crossing_stability_by_key[('ProvGigaPath', 'continuous')]['median_effect_sd'])} Q² and {fnum(foundation_crossing_stability_by_key[('TITAN', 'binary')]['median_effect_sd'])}/{fnum(foundation_crossing_stability_by_key[('GigaSSL', 'binary')]['median_effect_sd'])}/{fnum(foundation_crossing_stability_by_key[('ProvGigaPath', 'binary')]['median_effect_sd'])} AUROC. The threshold-derived support class agreed with the primary class in all five partitions for only {foundation_consensus_stability_overall['continuous']['all_five']}/{foundation_consensus_stability_overall['continuous']['tasks']} continuous and {foundation_consensus_stability_overall['binary']['all_five']}/{foundation_consensus_stability_overall['binary']['tasks']} binary pairs. We therefore retain support classes only as supplementary navigation tags and base interpretation on Q²/AUROC, paired differences, alternative-partition variability and ranks. The permutation/FDR-filtered TITAN screen remains clearly separated by cohort, task universe and evidential standard and is not used to make representation-level inferential claims."
))
responses.append((
    "5. Make upstream training exposure and pipeline differences central to interpretation",
    f"Agreed. We now describe the evaluated artifacts consistently as released representation pipelines and make clear that the estimand includes upstream preprocessing, spatial resolution, tile and slide encoders, released layer and representation-learning exposure. The Abstract Methods states that Giga-SSL development used TCGA and that direct overlap between representation-learning images and evaluated slides cannot be excluded, even though downstream molecular labels were held out. New main Table 1 places this qualification beside the reported TCGA-excluded pretraining corpora of TITAN and Prov-GigaPath and lists the representation dimension, released layer and principal retained pipeline differences. The Methods now state five explicit inclusion criteria: a ready-to-use slide-level TCGA artifact without WSI pixel reprocessing, deterministic slide identifiers, a fixed-length whole-slide vector, sufficient 32-cancer common-cohort coverage and reproducible release metadata for a distinct published whole-slide strategy. Supplementary Table S15e and foundation_model_exclusion_inventory.csv list UNI/UNI2-h, CONCH, Virchow, H-optimus, CHIEF, PRISM and Threads as representative exclusions and record the criterion not met; exclusion is not a model-quality judgement. We also surface the dedicated TITAN and Prov-GigaPath paired analysis in the main Results and Supplementary Table S15f. Both pipelines crossed the descriptive threshold in {ival(titan_prov_paired_by_outcome['continuous']['both_effect_threshold_crossing']):,}/1,507 continuous and {ival(titan_prov_paired_by_outcome['binary']['both_effect_threshold_crossing']):,}/426 binary pairs. TITAN had the higher effect in {ival(titan_prov_paired_by_outcome['continuous']['TITAN_higher_effect']):,} continuous and {ival(titan_prov_paired_by_outcome['binary']['TITAN_higher_effect']):,} binary pairs, while Prov-GigaPath had the higher effect in {ival(titan_prov_paired_by_outcome['continuous']['ProvGigaPath_higher_effect']):,} and {ival(titan_prov_paired_by_outcome['binary']['ProvGigaPath_higher_effect']):,}. Median Prov-GigaPath-minus-TITAN differences were {fnum(titan_prov_paired_by_outcome['continuous']['median_delta_ProvGigaPath_minus_TITAN'], 3)} Q² and {fnum(titan_prov_paired_by_outcome['binary']['median_delta_ProvGigaPath_minus_TITAN'], 3)} AUROC. We describe this as a cleaner comparison of reported pretraining exposure, not as external validation, isolated architecture quality or pipeline superiority."
))
responses.append((
    "6. Integrate tissue-source-site-code sensitivity into the primary evidence display",
    f"Agreed. Main Figure 3 now places TCGA tissue-source-site-code-grouped Q² or AUROC against the matched-random comparator for all three representation pipelines. Main Table 3 places the primary random-fold AUROC beside the median, interquartile range and crossing proportion across five alternative partitions, the grouped and matched-random AUROCs, and the number of contributing codes, realized outer folds and sparse-fold warning for THYM-GTF2I, THCA-BRAF, COAD strict MSI, READ-APC and COAD-APC. The Results also retain the larger TITAN finding that {ival(site_combined.get('below_threshold_models'))}/{ival(site_combined.get('screen_positive_models'))} candidates ({fnum(site_combined.get('below_threshold_percent'), 1)}%) fell below their original balanced-accuracy threshold, including READ-APC from {fnum(read_apc_site.get('random_balanced_accuracy'), 3)} to {fnum(read_apc_site.get('site_grouped_balanced_accuracy'), 3)} and COAD-APC from {fnum(coad_apc_site.get('random_balanced_accuracy'), 3)} to {fnum(coad_apc_site.get('site_grouped_balanced_accuracy'), 3)}. The paired matched-partition refits and code-only outcome AUROCs remain visible rather than reducing the result to a median change. We applied grouped outer and inner validation to all {foundation_union_counts['tasks']} pairs crossing in at least one representation for TITAN, Giga-SSL and Prov-GigaPath. Of {len(foundation_tss_grouped):,} representation-task fits, {len(foundation_tss_feasible_rows):,} were estimable; ACC genome doubling failed for all three representations because one grouped inner training partition contained a single class. We used no fallback. Metrics were calculated once from pooled patient-level outer out-of-fold predictions. A single-class outer fold contributed predictions to the pooled task metric, but no stand-alone fold AUROC or balanced accuracy was interpreted. Tasks contained {foundation_tss_code_min}-{foundation_tss_code_max} codes, outer test sets ranged from {min(ival(r['minimum_outer_test_n']) for r in foundation_tss_fold_adequacy_summary)} to {max(ival(r['maximum_outer_test_n']) for r in foundation_tss_fold_adequacy_summary)} patients and {sum(ival(r['tasks_with_four_outer_folds']) for r in foundation_tss_fold_adequacy_summary)} tasks used four rather than five outer folds. Among {foundation_tss_adequacy_by_outcome['binary']['tasks']} binary tasks, {foundation_tss_adequacy_by_outcome['binary']['tasks_with_single_class_outer_test_fold']} had a single-class outer test fold, {foundation_tss_adequacy_by_outcome['binary']['tasks_with_single_class_inner_validation_fold']} had a single-class inner validation fold and {foundation_tss_adequacy_by_outcome['binary']['tasks_with_single_class_inner_training_fold']} had a single-class inner training fold. Minimum outer and inner training-class counts were 1/5 and 0/1 positive/negative patients. The machine-readable task, outer-fold, inner-fold and model-registry records expose the realized fold count, code count, class minima, single-class indicators, sparse-fold flag, reasons and pooled-metric definition. The warning prevents sparse grouped estimates from receiving an unqualified robustness interpretation. Throughout, we describe this as sensitivity to grouping by a barcode-derived cohort-structure variable, not proof of technical confounding, site-level validation or transportability."
))
responses.append((
    "7. Report uncertainty as conditional and reduce dependence on threshold labels",
    "Agreed. Supplementary Table S6a now labels the initial primary-screen estimate and the five-repeat mean separately for every highlighted TITAN model. The note uses the full term '95% selection-conditioned patient-resampling interval for repeated out-of-fold predictions' and states compactly that the interval resamples patients from five fixed held-out prediction sets. It represents patient sampling variation conditional on those fitted partitions; it does not repeat screening, fold generation, tuning or fitting, does not correct winner's-curse selection, and is not a confidence interval for external generalisation. Each highlighted row also reports the median and interquartile range across the five partitions and the effect-threshold-crossing proportion. Main Table 3 reports the analogous alternative-partition median, interquartile range and crossing proportion for the five highlighted three-representation examples. The main Results now report median paired representation differences with descriptive cancer-cluster intervals, while Figure 3 and Supplementary Tables S15g and S15j retain continuous partition effects and ranks rather than relying on hard support categories. The supporting TITAN permutation paragraph is condensed in the main Methods. The Supplement retains the distinct p=1 statuses, complete-process permutation specification, 999-permutation Monte Carlo intervals and separately locked 9,999-permutation refinement. The synchronized highlighted-model CSV now records every repeat-distribution and crossing-proportion field."
))
responses.append((
    "8. Elevate pathology quality control, molecular-slide linkage and pooling limitations",
    f"Agreed. We promoted these constraints to main-text Box 1 and a dedicated Results synthesis. Box 1 reports linkage separately for Thorsson PanImmune, Taylor aneuploidy, Sanchez-Vega pathways, Gao fusion calls, cBioPortal MSI and MC3 mutations. Thorsson supplies participant identifiers only; the other five sources can be matched to the 15-character TCGA sample barcode. We state in the Box, Methods and Results that exact sample-barcode agreement cannot establish identity of the tissue portion, analyte, aliquot, block, tumour region or subclone. The source data provided no structured tumour cellularity, tissue area, artefact, biopsy-versus-resection or slide-quality field, so primary slide eligibility and equal weighting were not pathology adjudicated. The 35 generated no-residual-tumour mentions arose from six patients: TCGA-B6-A0IA and TCGA-B6-A0WV in BRCA, TCGA-55-8203 and TCGA-55-8507 in LUAD, TCGA-22-4596 in LUSC and TCGA-DX-AB2L in SARC. We removed all six before fold construction and refitted all {no_residual_sensitivity_total} screen-positive models in the four affected cancers. The original threshold remained for {no_residual_threshold_retained_total}/{no_residual_sensitivity_total}; all four highlighted affected models retained their thresholds, and the largest absolute change was SARC Macrophage Regulation Q² from 0.520 to 0.472. We label this same-image generated-text analysis as non-adjudicated and not a substitute for independent pathology review. We also report coordinate-wise mean-versus-median refits for all 323 TITAN candidates, within-patient pairwise cosine dispersion for all three representations and the maximum leave-one-slide-out centroid change. Mean-versus-median ranks correlated {fnum(median_pool_by_type.get('continuous', {}).get('correlation_with_mean'))} for continuous and {fnum(median_pool_by_type.get('binary', {}).get('correlation_with_mean'))} for binary models. Finally, we removed TCGA-DX-AB2L before fold construction and refitted every SARC candidate; {sum(float(r.get('exclusion_q2', 'nan')) >= 0.20 for r in sarc_exclusion_c)}/15 continuous and {sum(float(r.get('exclusion_balanced_accuracy', 'nan')) >= 0.60 for r in sarc_exclusion_b)}/5 binary models retained the threshold. Supplementary Tables S3b-S3d and the machine-readable patient- and endpoint-level files preserve the complete audit."
))
responses.append((
    "Methods section should report how sample-level CIBERSORT, mutation, inflammatory and pathway information was obtained",
    "Agreed. We expanded the main Methods to describe every outcome source, source file or sheet, barcode level, primary-sample filter, participant-level aggregation, missingness rule and transformation. The revised text states that we imported 50 published participant-level features from the Thorsson PanImmune_MS sheet rather than recalculating them. It identifies the 22 CIBERSORT LM22 fractions, methylation-derived leukocyte fraction, ten bulk-RNA inflammatory or immune signatures, repertoire metrics, mutation and neoantigen burdens, genomic-context quantities and the same-H&E TIL fraction. It also explains that we constructed tissue-specific mutation labels from MC3 PASS protein-altering calls and the Bailey driver catalogue, assigned wild type only inside the MC3-profiled denominator, and left unprofiled participants missing. Separate paragraphs now document the Sanchez-Vega pathway matrix, Taylor aneuploidy measures, Gao fusion denominator and calls, and cBioPortal MANTIS and MSIsensor fields, including sample type 01 filtering and participant aggregation. Supplementary Methods and new Table S13 Panel C provide the complete source map, and data/reference/outcome_source_acquisition_map.csv supplies the synchronized machine-readable record."
))
responses.append((
    "9. Separate direct genomic outcomes from derived and same-H&E reference phenotypes",
    "Agreed. Reference-label provenance now leads the Abstract Results and the first principal matched-benchmark Results paragraph. Main Table 2 and Supplementary Table S18 separate directly observed genomic alterations, binary composite genomic-context status, sequencing-derived continuous burdens, transcriptomic signatures, computationally inferred immune-cell fractions, continuous composite genomic-context scores and the same-H&E TIL fraction. At Q² at least 0.20 or AUROC at least 0.60, TITAN/Giga-SSL/Prov-GigaPath crossed 142/95/101 of 243 directly observed genomic-alteration tasks (58.4%/39.1%/41.6%); 95/75/79 of 183 binary composite genomic-context tasks (51.9%/41.0%/43.2%); 30/13/22 of 413 sequencing-derived burdens (7.3%/3.1%/5.3%); 100/47/60 of 279 transcriptomic signatures (35.8%/16.8%/21.5%); 27/18/18 of 638 inferred immune-cell fractions (4.2%/2.8%/2.8%); and 40/16/19 of 166 continuous composite scores (24.1%/9.6%/11.4%). All three representations crossed all 11 same-H&E TIL-fraction tasks. We excluded those 11 tasks from the default cross-modal continuous summary, which is now 197/94/119 of 1,496 tasks (13.2%/6.3%/8.0%). The manuscript describes CIBERSORT fractions, methylation-derived leukocyte estimates and RNA signatures as computational reference phenotypes and states that held-out agreement does not establish recovery of the originating assay, direct immune-cell abundance or clinical biomarker equivalence. We did not claim blinded pathologist review or spatial localisation because the retained artifacts contain only global vectors and no patch or tile embeddings, attention maps, relevance maps or WSI pixels. Supplementary Table S14 and morphology_context_examples.csv retain nearest-neighbour examples only as qualitative context and state the data and blinded-review steps required for a future spatial analysis."
))
responses.append((
    "10. The manuscript needs substantial condensation and visual simplification",
    f"Agreed. We rebuilt the reader-facing Abstract, Methods, Results, Discussion and Conclusions to retain the patient unit, released-pipeline scope, endpoint provenance, common probe, nested validation, principal partition sensitivities and a clear account of which tumour features were predictable. Chronology, complete fold audits, permutation resolution, class-size detail, morphology examples, object inventories, licensing and software mechanics remain in the Supplement or machine-readable companions. Main Table 2 reports {foundation_union_counts['tasks']} crossing cancer-endpoint pairs across {foundation_union_counts['unique_definitions']} feature definitions and the {foundation_all_three_counts['tasks']}-pair all-three core by reference-label class. Main Figure 3 integrates grouped and matched-random performance, and compact main Table 3 provides the highlighted target-level values with fold warnings. Main Figure 4 retains the author-requested two-patient COAD PathoFMPred example for TITAN, Giga-SSL and Prov-GigaPath inputs. Representation order and colours remain TITAN blue, Giga-SSL orange and Prov-GigaPath green throughout."
))
responses.append((
    "12. Complete the editorial package and substantially reduce the Supplement",
    "Addressed except for declarations that require facts from the authors. We rebuilt Additional file 1 as a compact interpretive companion. It retains Tables S1-S18 but limits long target-level displays to small summaries, removes redundant target-level ridge, morphology, selected-example, TITAN-atlas, multi-outcome and duplicate COAD figures, and reduces the visual inventory from 13 to six figures. Complete per-model, per-fold and target-level records remain in the synchronized CSV and RDS companions listed in the final inventory. The opening contents section now explains this division. We audited the 42-item bibliography and cite every retained reference in scientific context. Reference 35 keeps the unusual surname spelling Lamrca because PubMed PMID 35039450 and the canonical journal record list Angela Lamrca; the reference now gives the complete author list. The Additional-file section names supplementary_material_JTM.docx and both PathoFMPred PDFs exactly, and the build verifies that the files exist. Figure 1 now labels the three released patient and slide counts and the 10,165-slide exact common intersection; all figures keep TITAN blue, Giga-SSL orange and Prov-GigaPath green. We did not invent declarations. Competing interests, funding and CRediT contributions remain explicit corresponding-author completion items because the project files contain no verified facts for those statements. The final release tag, immutable commit and DOI likewise remain actions for the approved submission snapshot."
))
responses.append((
    "Minor and editorial comments",
    "Addressed throughout the synchronized manuscript package. We define Q² as the cross-validated coefficient of determination, q-value as the false-discovery-rate-adjusted empirical p-value, OOF as out-of-fold, the SC interval as the selection-conditioned patient-resampling interval for repeated out-of-fold predictions, and TCGA tissue-source-site code as the barcode-derived submitting-centre field at first use and in the abbreviation list. Where initial-screen and five-repeat estimates coexist, the same row or caption labels both and explains that different partitions can produce different values. We use 'sample-size maturity stratum' and keep threshold categories only as database-navigation tags. The two post hoc COAD radar cases, TCGA-AA-A01F and TCGA-A6-A56B, now appear only in Supplementary Figure S7 and Additional files 2 and 3. The radar prints original predictions at every vertex, and every binary report places 'Reference rank, not probability' beside the rank. Treatment-response narratives are absent because treatment was neither an input nor a validation outcome. We standardized Giga-SSL, Prov-GigaPath, PathoFMPred, cancer-endpoint pair and TCGA tissue-source-site code. No standardized LDA-score panel remains in the submitted figure set; any future zero line will be described only as a visual reference unless it equals the transformed fold-specific decision threshold. Model hashes, rank construction and report-field semantics remain in software documentation or machine-readable metadata rather than the biological Results. The literature crosswalk is labelled a targeted narrative audit and its search dates, strings, eligibility rules and colorectal mapping rule are reported. The draft cover letter presents the study as a reproducible translational research prioritisation resource in Medical Bioinformatics, Molecular Pathology, Disease Biomarkers and Translational Imaging, and explicitly states that it is not clinical validation."
))
for title, answer in responses:
    answer = answer.replace("tissue-source-site-code", "tissue-source-site code")
    answer = answer.replace("TSS", "TCGA tissue-source-site code")
    answer = answer.replace("Figures S1–S13", "Figures S1–S6")
    answer = answer.replace("Figures S1–S11", "Figures S1–S6")
    answer = answer.replace("Figures S1–S6", "Figures S1–S7")
    answer = answer.replace("Figure 2A", "Figure 2")
    answer = answer.replace("Main Figure 7 now has three panels", "Supplementary Figure S4 has three panels")
    answer = answer.replace("Figure 6, Table S10b", "Supplementary Figure S4 and Table S10b")
    answer = answer.replace("Figure 6 caption", "Supplementary Figure S4 caption")
    answer = answer.replace("Figure 4 moves the central TITAN tissue-source-site code sensitivity forward", "Supplementary Figure S4 presents the central TITAN tissue-source-site code sensitivity")
    answer = answer.replace("Figures 5 and 6 show 12 TITAN models with enlarged typography. Figure 7 uses normalized cancer-specific crossing rates rather than raw counts.", "Tables S7 and S8 retain concise top-result summaries, and Table S17 reports normalized cancer-specific crossing rates.")
    answer = answer.replace("Figure 3 reports normalized cancer-level crossing rates", "Supplementary Table S17 reports normalized cancer-level crossing rates")
    answer = answer.replace("Figure 8", "Figure 4")
    answer = answer.replace("Main Figure 8", "Main Figure 4")
    answer = answer.replace("Main Table 4 now reports", "Supplementary Table S15j reports")
    answer = answer.replace("Table 5 reports", "Supplementary Table S15j reports")
    answer = answer.replace("Figure 2 shows normalized three-model breadth and paired effects", "Figure 2 shows complete paired target-level Q²/AUROC distributions; catalogue-normalized breadth is reported in the main Results, Table 1 and Supplementary Table S17")
    answer = answer.replace("Main Table 1 gives eligible denominators", "Main Table 2 gives eligible denominators")
    answer = answer.replace("Main Table 1 now reports 340", "Main Table 2 now reports 340")
    answer = answer.replace("main Results, Table 1 and Supplementary Table S17", "main Results, Table 2 and Supplementary Table S17")
    answer = answer.replace("Figures 3 and 4 and their captions both state 12 displayed models", "Supplementary Tables S7 and S8 retain concise top-result summaries")
    answer = answer.replace("Figure 6 points to the new complete cancer-level Table S1b", "Figure 3 reports normalized cancer-level crossing rates")
    answer = answer.replace("Both panels of Figure 5 now use the largest five-repeat mean outcome-specific metric", "The synchronized held-out-prediction files retain the selected examples and their selection rule")
    answer = answer.replace("Figure 4 labels now show balanced accuracy, AUROC, PR-AUC and prevalence, and Figure 5B states PR-AUC with its prevalence no-skill reference", "Supplementary Table S8 and the synchronized binary files report balanced accuracy, AUROC, PR-AUC and prevalence")
    answer = answer.replace("Figure 5B is explicitly a score-distribution illustration", "The removed score-distribution illustration was explicitly non-calibrated")
    answer = answer.replace("Figure 2 now integrates this cross-tabulation as Panel D immediately after the central comparison", "Figure 3 presents this cross-tabulation immediately after the normalized breadth/effect comparison")
    answer = answer.replace("standard-evidence", "larger-sample-stratum")
    answer = answer.replace("Standard evidence", "The larger-sample stratum")
    answer = answer.replace("evidence maturity", "sample-size stratification")
    answer = answer.replace("R1–R4 internal prioritisation", "deprecated R1–R4 registry navigation")
    answer = answer.replace(
        "17/35 binary and 8/12 continuous",
        f"{ival(probe_by_type['binary']['winner_retained'])}/{ival(probe_by_type['binary']['targets'])} binary and {ival(probe_by_type['continuous']['winner_retained'])}/{ival(probe_by_type['continuous']['targets'])} continuous"
    )
    answer = answer.replace("The former Figure 7 section is now labelled as a secondary, larger TITAN-specific audit", "Supplementary Figure S4 retains the larger TITAN-specific cohort-structure audit")
    answer = answer.replace("Supplementary Figures S9 and S10", "[[TOP_TABLES]]")
    answer = answer.replace("Supplementary Figure S13", "[[WINNER_FIGURE]]")
    answer = answer.replace("Supplementary Figure S12", "[[BREADTH_FIGURE]]")
    answer = answer.replace("Supplementary Figure S11", "[[MAIN_RADAR]]")
    answer = answer.replace("Supplementary Figure S10", "[[BINARY_TABLE]]")
    answer = answer.replace("Supplementary Figure S9", "[[CONTINUOUS_TABLE]]")
    answer = answer.replace("Supplementary Figure S8", "[[SITE_FIGURE]]")
    answer = answer.replace("Supplementary Figure S7", "[[PREDICTION_RECORDS]]")
    answer = answer.replace("Supplementary Figure S6", "[[CONSENSUS_FIGURE]]")
    answer = answer.replace("Supplementary Figure S5", "[[CONTINUOUS_RELIABILITY_FIGURE]]")
    answer = answer.replace("Supplementary Figures S3–S4", "[[MULTIOUTCOME_RECORDS]]")
    answer = answer.replace("Supplementary Figure S2", "[[MORPHOLOGY_TABLE]]")
    answer = answer.replace("[[TOP_TABLES]]", "Supplementary Tables S7 and S8")
    answer = answer.replace("[[WINNER_FIGURE]]", "Supplementary Figure S6")
    answer = answer.replace("[[BREADTH_FIGURE]]", "Supplementary Figure S5")
    answer = answer.replace("[[MAIN_RADAR]]", "Supplementary Figure S7")
    answer = answer.replace("[[BINARY_TABLE]]", "Supplementary Table S8")
    answer = answer.replace("[[CONTINUOUS_TABLE]]", "Supplementary Table S7")
    answer = answer.replace("[[SITE_FIGURE]]", "Supplementary Figure S4")
    answer = answer.replace("[[PREDICTION_RECORDS]]", "Supplementary Figure S7 and synchronized held-out-prediction records")
    answer = answer.replace("[[CONSENSUS_FIGURE]]", "Supplementary Figure S3")
    answer = answer.replace("[[CONTINUOUS_RELIABILITY_FIGURE]]", "Supplementary Figure S2")
    answer = answer.replace("[[MULTIOUTCOME_RECORDS]]", "machine-readable multi-outcome summaries")
    answer = answer.replace("[[MORPHOLOGY_TABLE]]", "Supplementary Table S14")
    answer = answer.replace("Main Figure 4", "Supplementary Figure S7")
    answer = answer.replace("main Figure 4", "Supplementary Figure S7")
    answer = answer.replace("Figure 4", "Supplementary Figure S7")
    answer = answer.replace("Main Figure 3 now applies the three representation-specific fitted resources", "Supplementary Figure S7 applies the three representation-specific fitted resources")
    answer = answer.replace("remain in the main manuscript as a PathoFMPred software example", "are retained in the Supplement as a post hoc PathoFMPred software example")
    answer = answer.replace("reduces the visual inventory from 13 to six figures", "reduces the visual inventory from 13 to seven figures")
    resp.add_heading(title, 1); resp.add_paragraph(answer)
replace_reader_facing_chronology_terms(resp)
standardize_matched_evidence_terms(resp)
standardize_released_pipeline_terms(resp)
standardize_tissue_source_site_terms(resp)
standardize_sample_size_maturity_terms(resp)
standardize_literature_audit_terms(resp)
remove_em_dashes(resp)
resp.save(OUT / "response_to_reviewer_JTM.docx")


# Replace the accumulated development-history response with a concise,
# submission-facing response synchronized to the final 1-to-20-component
# analysis snapshot. The detailed change history remains available in Git.
resp = setup(Document(), "Response to reviewer")
resp.add_heading("Response to reviewer", 0)
resp.add_paragraph("Manuscript: " + MANUSCRIPT_TITLE)
resp.add_paragraph(
    "We thank the reviewer for the detailed statistical, biological and "
    "editorial assessment. We rebuilt the analyses with fastPLS 0.3, used the "
    "patient as the unit of analysis and cross-validation, synchronized the "
    "manuscript with the complete result files, and separated the matched "
    "three-representation benchmark from the supporting permutation and "
    "false-discovery-rate-controlled TITAN screen. The responses below report "
    "the final analysis snapshot."
)

final_responses = [
    (
        "1. Scientific hierarchy and study scope",
        "The matched benchmark is now the central study. It includes 8,241 "
        "patients, 30 cancers and 3,389 cancer-endpoint pairs, comprising 2,963 "
        "continuous and 426 binary tasks evaluated with identical outcome "
        "subsets and folds for TITAN, Giga-SSL and Prov-GigaPath. The larger "
        "9,404-patient TITAN analysis is presented as a supporting screen across "
        "32 cancers and 3,633 eligible tasks. PathoFMPred is described as a "
        "secondary research interface and model registry rather than a source "
        "of additional validation evidence."
    ),
    (
        "2. Released representation pipelines and upstream exposure",
        "The title, Abstract and Methods now state that the study compares three "
        "released representation pipelines under a common PLS-based probe. The "
        "estimand includes upstream preprocessing, spatial-resolution assumptions, "
        "the tile and slide encoders, the released layer and representation-learning "
        "exposure. We report that the published TITAN and Prov-GigaPath pretraining "
        "corpora excluded TCGA, whereas Giga-SSL development used TCGA and direct "
        "overlap with the evaluated images cannot be excluded. Downstream molecular "
        "labels remained held out in every patient-level fold. The Supplement also "
        "lists relevant models that lacked a compatible released slide-level TCGA "
        "artifact with identifiers and common-cohort coverage."
    ),
    (
        "3. Histological input matching and patient-level pooling",
        "The revised Methods report the released patient and slide counts for all "
        "three pipelines. Of the 8,241 common patients, 8,207 had identical slide "
        "sets across all representations, and the exact common-slide intersection "
        "contained 10,165 slides. An exact-slide sensitivity produced negligible "
        "median changes and preserved the aggregate conclusions. Slides were pooled "
        "before outcome matching, and patients rather than slides were assigned to "
        "folds. Mean-versus-median pooling, within-patient cosine dispersion, "
        "leave-one-slide-out centroid change and exclusion of the 30-slide SARC "
        "participant are reported in the Supplement and machine-readable files."
    ),
    (
        "4. Binary estimand and operating point",
        "The matched binary benchmark is now AUROC-centred. Pooled inner out-of-fold "
        "AUROC selects 1 to 20 PLS components, and pooled outer out-of-fold AUROC is "
        "the primary paired statistic. A threshold selected only from inner "
        "training predictions supplies balanced accuracy, sensitivity, specificity, "
        "PPV and NPV. PR-AUC is reported with the observed TCGA prevalence as its "
        "no-skill reference. Empirical-prior, equal-prior and training-optimized "
        "class calls are retained as operating-rule sensitivities rather than as "
        "alternative definitions of representation quality."
    ),
    (
        "5. Component range and downstream-probe dependence",
        "All primary matched models now use a 1 to 20 component grid. Component "
        "selection, ceiling frequency, constant-feature handling and numerical "
        "failures are reported for every representation. The completed primary "
        "atlas contains no silent fallback. Five constant Giga-SSL dimensions were "
        "retained to preserve the released schema; training-fold centering maps "
        "them to zero. A symmetric ridge comparison uses identical partitions and "
        "tuning principles on a metadata-selected subset. We interpret every "
        "representation result as conditional on the specified downstream probe "
        "and make no claim of intrinsic foundation-model superiority."
    ),
    (
        "6. Descriptive thresholds, multiplicity and uncertainty",
        "Q2 at least 0.20 and AUROC at least 0.60 are called effect-threshold "
        "crossings throughout the matched benchmark. They are catalogue-navigation "
        "rules, not statistical discoveries. Paired Q2 and AUROC estimates, "
        "alternative-partition variability, crossing proportions and rank stability "
        "receive priority over hard categories. In the separate TITAN screen, every "
        "eligible task remained in the relevant Benjamini-Hochberg denominator; "
        "tasks that failed the performance checkpoint and conservatively "
        "early-stopped tests received distinct p=1 statuses. Selected tests were "
        "refined to 9,999 full-process permutations with Monte Carlo intervals. "
        "Repeated-validation intervals are labelled selection-conditioned "
        "patient-resampling intervals for fixed repeated out-of-fold predictions "
        "and are not presented as external-performance confidence intervals."
    ),
    (
        "7. Tissue-source-site-code sensitivity",
        "Grouping complete TCGA tissue-source-site codes in both inner and outer "
        "validation is now part of the principal evidence display. In the supporting "
        "TITAN screen, 210 of 869 candidates fell below their original effect "
        "threshold, including marked attenuation of COAD-APC and READ-APC. The "
        "machine-readable audit reports contributing codes, realized fold count, "
        "training and test class counts, single-class test folds, pooled outer "
        "metrics and a fold-adequacy flag. Matched-random partitions separate part "
        "of the fold-size and class-balance effect. We consistently describe this "
        "as sensitivity to a barcode-derived cohort-structure variable, not as "
        "institutional validation, proof of confounding or evidence of external "
        "transportability."
    ),
    (
        "8. Biological yield and endpoint provenance",
        "The Results now lead with what can be predicted. Excluding 11 same-H&E "
        "tasks, continuous Q2 crossings were 633 for TITAN, 351 for Giga-SSL and "
        "430 for Prov-GigaPath among 2,952 tasks. Binary AUROC crossings were "
        "230, 166 and 176 among 426 tasks. Direct genomic-alteration crossings were "
        "137, 92 and 98 among 243 tasks. Named cross-pipeline examples include "
        "THYM-GTF2I, THCA-BRAF, LGG-IDH1 and TP53, COAD strict MSI, UCEC fusion "
        "status, TGCT TGF-beta response and selected RNA-derived pathway activities. "
        "Direct genomic alterations, sequencing-derived burdens, transcriptomic "
        "signatures, inferred immune fractions, composite scores and same-H&E "
        "quantities are reported separately. CIBERSORT fractions and RNA signatures "
        "are described as agreement with computational reference phenotypes rather "
        "than direct immune-cell measurements."
    ),
    (
        "9. Outcome acquisition, missingness and molecular-slide linkage",
        "The Methods now identify the source file or worksheet, identifier level, "
        "primary-sample filter, participant aggregation, missingness rule and "
        "transformation for Thorsson PanImmune features, MC3 and Bailey mutation "
        "labels, Sanchez-Vega pathway status, Taylor aneuploidy and genome doubling, "
        "Gao fusions, cBioPortal MSI fields and UCSC Xena RNA pathway scores. Wild "
        "type was assigned only within a documented profiled denominator. Source "
        "absence remained missing. Participant-level and sample-barcode linkage are "
        "distinguished, and the paper states that even an exact sample barcode does "
        "not prove identity of the block, portion, analyte, aliquot, tumour region "
        "or subclone."
    ),
    (
        "10. Pathology quality control",
        "The Methods state that no structured tumour-cellularity, tissue-area, "
        "artefact, biopsy-versus-resection or slide-quality field was available. "
        "Generated narrative text identified 35 no-residual-tumour mentions across "
        "six patients, but these labels were derived from the same slides and were "
        "not treated as independent pathology adjudication. A clearly labelled "
        "post hoc exclusion sensitivity refitted affected models after removing the "
        "six patients. This limitation and the equal-weight pooling assumption now "
        "appear in the main Methods and Table 2 rather than only in supplementary "
        "caveats."
    ),
    (
        "11. Literature positioning and biological interpretation",
        "The Background now introduces self-supervised foundation models, including "
        "DINOv2 as a general vision example, and explains how fixed slide vectors "
        "support task-specific linear models. The manuscript compares the present "
        "resource with the principal pan-cancer and endpoint-specific H&E studies. "
        "The mutation crosswalk is explicitly called a targeted narrative audit; "
        "its databases, date, search strings, inclusion criteria, preprint handling "
        "and colorectal mapping rule are documented. The Discussion focuses on "
        "named consensus and discordant biological signals and avoids claims of "
        "endpoint novelty that the audit cannot substantiate."
    ),
    (
        "12. PathoFMPred examples and interpretation",
        "Main Figures 5 and 6 retain the requested TCGA-AA-A01F and TCGA-A6-A56B "
        "COAD examples. The continuous panels show only endpoints predictable for "
        "the selected cancer and representation and print each original prediction. "
        "The binary panel shows every predictable binary output across the three "
        "representations, including mutations, MSI, genome doubling and oncogenic "
        "pathway status. Binary scores are labelled uncalibrated, and every reference "
        "rank is labelled not a probability. Treatment response is not narrated. "
        "Complete package-format reports for the same two patients are supplied as "
        "Additional files 2 and 3."
    ),
    (
        "13. PathoFMPred licensing, access and fitted-object inventory",
        "Contributor-authored PathoFMPred source code and documentation are released "
        "under the MIT License. Fitted objects and third-party inputs are expressly "
        "excluded from that source-code grant. The public repository contains a "
        "minimal Giga-SSL example and offers explicit checksum-verified post-install "
        "downloads for permitted Giga-SSL and Prov-GigaPath collections, each with "
        "separate asset notices and upstream attribution. The TITAN collection "
        "remains only in the access-controlled PathoFMPred-private repository because "
        "the upstream terms describe models trained on TITAN outputs as derivatives "
        "and restrict redistribution. The public package provides generic creation "
        "and object-level prediction functions so an authorized user can build a "
        "local object from independently obtained feature and outcome tables."
    ),
    (
        "14. Package validation and reproducibility",
        "Both package variants use fastPLS 0.3 at the recorded Git commit, retain "
        "the package defaults for rSVD oversampling and power iterations, and use "
        "components 1 to 20. The builder requires unique outcome IDs, permits "
        "repeated feature IDs, pools repeated rows by mean or optional median, "
        "requires more than 100 matched IDs, reports unmatched IDs and endpoint "
        "missingness, and records the positive class for binary outcomes. Source "
        "tests and R CMD check --as-cran complete without errors or warnings. Model "
        "downloads and local objects are verified by SHA-256 and structural "
        "validation."
    ),
    (
        "15. Presentation and supplementary material",
        "The manuscript was condensed around the matched cohort, biological yield, "
        "representation-specific strengths, patient-level observed-versus-predicted "
        "values, partition sensitivity and translational interpretation. Figure 1 "
        "now shows patient and slide overlap rather than an analysis workflow. "
        "Figure 2 summarizes which tumour-feature classes and named endpoints are "
        "predictable. Figure 3 compares the representation leading each feature "
        "class, and Figure 4 shows observed versus held-out predicted values. The "
        "Supplement is restricted to compact interpretive Tables S1 to S13, four "
        "figures on separate pages and a domain-level inventory of complete "
        "machine-readable companions. Terminology, figure colours, representation "
        "order, table citations and additional-file names were standardized."
    ),
    (
        "16. External validation and remaining submission items",
        "No independent cohort was added. The Abstract, Discussion, Conclusions, "
        "package outputs and cover letter therefore describe all performance as "
        "internally derived TCGA research estimates and do not claim deployment, "
        "clinical validity, assay replacement or transportability. The remaining "
        "submission-dependent items are the authors' confirmed competing-interest, "
        "funding and CRediT statements and the DOI or immutable archive identifier "
        "for the author-approved release. These facts were not invented in the draft."
    ),
]

for title, answer in final_responses:
    resp.add_heading(title, 1)
    resp.add_paragraph(answer)

remove_em_dashes(resp)
resp.save(OUT / "response_to_reviewer_JTM.docx")


# Draft cover letter for author approval. The standard-business-brief preset is
# implemented through the shared setup(): Letter page, 1-inch margins, Calibri
# body text, blue heading hierarchy and restrained paragraph spacing.
cover = setup(Document(), "Draft cover letter to Journal of Translational Medicine")
cover.add_heading("Draft cover letter", 0)
add_labelled(cover, "Date:", " 20 September 2026")
add_labelled(cover, "To:", " Editors, Journal of Translational Medicine")
add_labelled(cover, "Article type:", " Research Article, Molecular Pathology")
add_labelled(cover, "Manuscript:", " " + MANUSCRIPT_TITLE)
cover.add_paragraph("Dear Editors,")
cover.add_paragraph(
    "We submit this manuscript for consideration in Journal of Translational Medicine. We compare three released pathology representation pipelines, TITAN, Giga-SSL and Prov-GigaPath, in a patient-level TCGA benchmark across 32 cancers. The study evaluates direct genomic alterations separately from sequencing-derived burdens, transcriptomic signatures, computationally inferred immune-cell fractions, composite genomic-context scores and same-H&E reference phenotypes."
)
cover.add_paragraph(
    "The work provides a reproducible translational research prioritisation resource. Its principal contribution is the matched use of identical patients, outcomes and folds across the three representation pipelines, combined with patient-first slide pooling, alternative-partition analyses, grouping by TCGA tissue-source-site code and explicit reporting of negative, ineligible and sample-size-limited results. The supporting permutation/FDR-filtered TITAN screen adds deeper internal qualification for one representation. PathoFMPred provides a secondary research interface and registry for applying compatible fitted models; it does not add validation evidence."
)
cover.add_paragraph(
    "We believe the manuscript fits the journal's interests in Medical Bioinformatics, Molecular Pathology, Disease Biomarkers and Translational Imaging. It identifies tumour-feature associations that merit locked independent testing while showing where representation choice, downstream probe and cohort structure alter prioritisation. The study does not claim clinical validation, assay replacement or transportability beyond TCGA. We state the absence of an independent external cohort prominently and position every output as an internally derived research estimate."
)
cover.add_paragraph(
    "The accompanying manuscript, Supplementary Material, machine-readable companions and response document report the analysis scope, reference-label provenance, uncertainty limits, pathology-quality constraints, molecular-slide linkage, software access conditions and upstream representation terms. We hope that this transparent benchmark will support careful selection of candidates for independent translational validation."
)
cover.add_paragraph("Sincerely,")
cover.add_paragraph("Stefano Cacciatore, PhD\nCorresponding author\nBioinformatics Unit, International Centre for Genetic Engineering and Biotechnology\nCape Town, South Africa\nstefano.cacciatore@icgeb.org")
standardize_released_pipeline_terms(cover)
standardize_tissue_source_site_terms(cover)
standardize_sample_size_maturity_terms(cover)
standardize_literature_audit_terms(cover)
remove_em_dashes(cover)
cover.save(OUT / "cover_letter_JTM.docx")


def _parse_numeric_citation_group(raw):
    values = []
    for token in raw.split(","):
        token = token.strip()
        if "-" in token:
            start, end = (int(value.strip()) for value in token.split("-", 1))
            values.extend(range(start, end + 1))
        else:
            values.append(int(token))
    return values


def _format_numeric_citation_group(values):
    values = sorted(set(values))
    runs = []
    start = previous = values[0]
    for value in values[1:]:
        if value == previous + 1:
            previous = value
            continue
        runs.append(str(start) if start == previous else f"{start}-{previous}")
        start = previous = value
    runs.append(str(start) if start == previous else f"{start}-{previous}")
    return ",".join(runs)


_CITATION_PATTERN = re.compile(r"\[([0-9][0-9,\- ]*)\]")


def _citation_ids(text_value, maximum):
    values = []
    for match in _CITATION_PATTERN.finditer(text_value):
        group = _parse_numeric_citation_group(match.group(1))
        if all(value <= maximum for value in group):
            values.extend(group)
    return values


def _remap_text_node_citations(document, mapping):
    def replace(match):
        old_values = _parse_numeric_citation_group(match.group(1))
        if not old_values or any(value not in mapping for value in old_values):
            return match.group(0)
        new_values = [mapping[value] for value in old_values]
        return "[" + _format_numeric_citation_group(new_values) + "]"

    for text_node in document.element.body.iter(qn("w:t")):
        if text_node.text:
            text_node.text = _CITATION_PATTERN.sub(replace, text_node.text)


def _renumber_references_by_first_appearance(main_path, supplement_path):
    """Synchronize Vancouver numbering across the main paper and Supplement."""
    main_document = Document(main_path)
    supplement_document = Document(supplement_path)
    reference_heading = next(
        index for index, paragraph in enumerate(main_document.paragraphs)
        if paragraph.text.strip() == "References"
    )
    reference_paragraphs = []
    reference_text = {}
    for paragraph in main_document.paragraphs[reference_heading + 1:]:
        match = re.match(r"^(\d+)\.\s+(.*)$", paragraph.text.strip(), flags=re.S)
        if match:
            number = int(match.group(1))
            reference_paragraphs.append(paragraph)
            reference_text[number] = match.group(2)
    maximum = len(reference_paragraphs)
    if sorted(reference_text) != list(range(1, maximum + 1)):
        raise RuntimeError("The bibliography is not consecutively numbered before renumbering.")

    first_appearance = []
    for paragraph in main_document.paragraphs[:reference_heading]:
        for number in _citation_ids(paragraph.text, maximum):
            if number not in first_appearance:
                first_appearance.append(number)
    for paragraph in supplement_document.paragraphs:
        for number in _citation_ids(paragraph.text, maximum):
            if number not in first_appearance:
                first_appearance.append(number)
    for table in supplement_document.tables:
        for row in table.rows:
            for cell in row.cells:
                for paragraph in cell.paragraphs:
                    for number in _citation_ids(paragraph.text, maximum):
                        if number not in first_appearance:
                            first_appearance.append(number)
    missing = sorted(set(reference_text) - set(first_appearance))
    if missing:
        raise RuntimeError("Uncited bibliography entries: " + ", ".join(map(str, missing)))

    mapping = {
        old_number: new_number
        for new_number, old_number in enumerate(first_appearance, start=1)
    }
    _remap_text_node_citations(main_document, mapping)
    _remap_text_node_citations(supplement_document, mapping)
    for new_number, (paragraph, old_number) in enumerate(
            zip(reference_paragraphs, first_appearance), start=1):
        paragraph.text = f"{new_number}. {reference_text[old_number]}"

    main_document.save(main_path)
    supplement_document.save(supplement_path)

    check_main = Document(main_path)
    check_supplement = Document(supplement_path)
    check_reference_heading = next(
        index for index, paragraph in enumerate(check_main.paragraphs)
        if paragraph.text.strip() == "References"
    )
    observed = []
    for paragraph in check_main.paragraphs[:check_reference_heading]:
        for number in _citation_ids(paragraph.text, maximum):
            if number not in observed:
                observed.append(number)
    for paragraph in check_supplement.paragraphs:
        for number in _citation_ids(paragraph.text, maximum):
            if number not in observed:
                observed.append(number)
    for table in check_supplement.tables:
        for row in table.rows:
            for cell in row.cells:
                for paragraph in cell.paragraphs:
                    for number in _citation_ids(paragraph.text, maximum):
                        if number not in observed:
                            observed.append(number)
    if observed != list(range(1, maximum + 1)):
        raise RuntimeError("Reference first-appearance order is not sequential: " + repr(observed))


_renumber_references_by_first_appearance(
    OUT / "manuscript_JTM_multifoundation_atlas.docx",
    OUT / "supplementary_material_JTM.docx",
)

for source_name, output_name in (
    ("COAD_example_A_all_models.pdf", "Additional_file_2_COAD_example_A_PathoFMPred_report.pdf"),
    ("COAD_example_B_all_models.pdf", "Additional_file_3_COAD_example_B_PathoFMPred_report.pdf"),
):
    shutil.copyfile(ROOT / "results" / "reports" / source_name, OUT / output_name)

print(OUT / "manuscript_JTM_multifoundation_atlas.docx")
print(OUT / "supplementary_material_JTM.docx")
print(OUT / "response_to_reviewer_JTM.docx")
print(OUT / "cover_letter_JTM.docx")
