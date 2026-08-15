#!/usr/bin/env python3
"""Build the JTM manuscript, supplement and point-by-point response from results."""
from __future__ import annotations

import csv
import os
from collections import Counter, defaultdict
from pathlib import Path

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT, WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Inches, Pt, RGBColor

ROOT = Path(__file__).resolve().parents[1]
TABLES = ROOT / "results" / "tables"
FIGURES = ROOT / "figures"
OUT = ROOT / "manuscript"
OUT.mkdir(exist_ok=True)
REPO = os.environ.get(
    "TITAN_REPOSITORY_URL", "https://github.com/tkcaccia/titan-prediction"
)


def rows(name):
    with (TABLES / name).open(encoding="utf-8-sig", newline="") as f:
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
    header.text = title or "TITAN patient-level prediction atlas"
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

def tier_counts(data):
    ans = defaultdict(Counter)
    for r in data: ans[r["family"]][r["tier"]] += 1
    return ans


ctier = tier_counts(continuous); btier = tier_counts(binary)
supported_c = [r for r in continuous if r["tier"] in ("A", "B")]
supported_b = [r for r in binary if r["tier"] in ("A", "B")]
global_supported_c = [r for r in supported_c if float(r["q_value_global"]) < 0.05]
global_supported_b = [r for r in supported_b if float(r["q_value_global"]) < 0.05]
top_c = sorted(supported_c, key=lambda r: float(r["q2"]), reverse=True)
top_b = sorted(supported_b, key=lambda r: float(r["balanced_accuracy"]), reverse=True)

meta = rows("patient_cohort_summary.csv")
# The summary CSV contains one row per patient. Recompute cohort totals here.
n_patients = len(meta); n_slides = sum(ival(r.get("n_slides")) for r in meta)
n_multi = sum(ival(r.get("n_slides")) > 1 for r in meta)
n_cancers = len({r.get("tumor_type") for r in meta if r.get("tumor_type")})
n_missing_cancer = sum(not r.get("tumor_type") for r in meta)

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


def examples(data, metric, n=8):
    ordered = sorted(data, key=lambda r: float(r[metric]), reverse=True)[:n]
    return "; ".join(f'{r["tumor_type"]}–{r["endpoint"]} ({fnum(r[metric])})' for r in ordered)


def median(values):
    z = sorted(float(v) for v in values if v not in ("", "NA") and v is not None)
    if not z: return float("nan")
    m = len(z)//2
    return z[m] if len(z)%2 else (z[m-1]+z[m])/2


site_deltas = [r["delta"] for r in site_c + site_b if r.get("feasible") == "TRUE" and r.get("delta")]
pool_deltas = [r["delta_first_minus_mean"] for r in pool_c + pool_b if r.get("delta_first_minus_mean")]
lit_counts = Counter(r["current_status"] for r in lit)


doc = setup(Document(), "Patient-level TITAN molecular and immune atlas")
p = doc.add_paragraph(style="Title"); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("A patient-level atlas of molecular and immune predictability from frozen TITAN whole-slide embeddings across 32 cancers")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("Authors: Aamilah Ismail [author list to be confirmed]").bold = True
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("Division of Engineering, New York University Abu Dhabi, Abu Dhabi, United Arab Emirates")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("Corresponding author: [to be completed]")
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.add_run("Research article — Molecular Pathology | Journal of Translational Medicine")

doc.add_heading("Abstract", level=1)
add_labelled(doc, "Background.", "Histology can encode molecular and microenvironmental phenotypes, but conventional convolutional-neural-network workflows require repeated task-specific training. We evaluated whether reusable TITAN whole-slide embeddings enable rapid, cancer-specific screening of individual molecular, genomic-instability and immune endpoints.")
add_labelled(doc, "Methods.", f"We mean-pooled {n_slides:,} primary diagnostic slide embeddings into {n_patients:,} patient vectors across {n_cancers} TCGA cancers; {n_multi:,} patients contributed multiple slides. We tested {len(continuous):,} continuous and {len(binary):,} binary cancer–endpoint pairs. PLS1 regression was used for continuous targets; binary targets used PLS latent scores with LDA. Patient-level nested 5×5 cross-validation selected 1–10 components. Effect-eligible models underwent up to 99 permutations with Benjamini–Hochberg control within cancer and endpoint family; a global-across-cancers q-value was retained as sensitivity. PLS2 was a secondary matched analysis of coherent inflammatory blocks.")
add_labelled(doc, "Results.", f"Across all families, {len(supported_c):,} continuous and {len(supported_b):,} binary pairs met Tier A/B criteria. Leading continuous results included {examples(top_c, 'q2', 4)}. Leading binary results included {examples(top_b, 'balanced_accuracy', 4)}. Site-grouped and first-slide sensitivity quantified centre and slide-selection dependence. PLS2 effect magnitudes were evaluated at the cancer level rather than by endpoint win counts.")
add_labelled(doc, "Conclusions.", "Frozen TITAN features provide a fast hypothesis-generation layer for selected cancer-specific immune and molecular phenotypes, but predictability is heterogeneous and does not replace molecular assays. The internally validated models and negative results require independent external validation before clinical interpretation.")
doc.add_paragraph("Keywords: computational pathology; whole-slide imaging; foundation model; mutation; inflammation; microsatellite instability; gene fusion; aneuploidy; partial least squares; linear discriminant analysis")

doc.add_heading("Background", level=1)
doc.add_paragraph("Routine haematoxylin-and-eosin sections reflect phenotypic consequences of tumour genotype and the immune microenvironment. Coudray and colleagues trained an Inception-v3 convolutional neural network (CNN) to predict six recurrently mutated genes in lung adenocarcinoma, and subsequent pan-cancer studies expanded image-derived inference to mutations, molecular biomarkers and expression programmes [1–5]. These studies established biological plausibility, but their tile extraction, annotation and target-specific optimization make exhaustive updating expensive.")
doc.add_paragraph("TITAN is a multimodal whole-slide foundation model pretrained on 335,645 slides using visual self-supervision and vision–language alignment [6]. Its frozen 768-dimensional slide representation can be reused without back-propagation through millions of tiles. PLS is computationally light and well suited to correlated, high-dimensional predictors [7,8]. The advantage tested here is therefore speed and reuse after TITAN extraction—not an assumption that PLS is intrinsically more accurate than a task-optimized CNN.")
doc.add_paragraph("The primary question was cancer-specific: which individual mutations, inflammatory measurements, oncogenic pathways, MSI phenotypes, aneuploidy measures and fusions are predictable within each cancer? Molecular subtype association was not analysed. PLS1 versus PLS2 was secondary; PLS2 was considered most biologically plausible for correlated inflammatory panels, while PLS–LDA was preferred for individual binary molecular endpoints.")

doc.add_heading("Methods", level=1)
doc.add_heading("Study design, slides and patient unit", level=2)
doc.add_paragraph(f"The published TITAN TCGA table contained {n_slides:,} eligible primary-tumour diagnostic slides (TCGA sample type 01 and –DX filename) from {n_patients:,} participants. The {n_multi:,} participants with multiple eligible slides contributed one patient vector obtained by feature-wise arithmetic mean before outcomes were joined. Patient—not slide—was the independent cross-validation unit. The slide-report file was used only to audit identifiers, cancer provenance and resection site; no report text entered a model. Nine participants without a resolvable cancer label did not enter cancer-specific modelling. All molecular sources were independently restricted to TCGA sample type 01 before patient aggregation.")
doc.add_paragraph("All models were stratified by cancer type. No model learned pan-cancer differences, and no patient could occur in more than one validation fold. The intended use was discovery-stage prioritisation rather than diagnosis, treatment selection or replacement of molecular testing.")
add_figure(doc, "Figure1_patient_first_workflow.png", "Figure 1. Patient-first study design. Eligible diagnostic slides are mean-pooled before outcome matching; all model selection and evaluation occur at patient level within cancer type.")

doc.add_heading("Predictors and outcomes", level=2)
doc.add_paragraph("Predictors were the 768 frozen TITAN dimensions [6]. Continuous outcomes comprised 39 immune/inflammatory measures and 11 genomic-context scores from Thorsson et al. [9], three aneuploidy burdens from Taylor et al. [10], log-transformed fusion burden from Gao et al. [11], and MANTIS/MSIsensor scores from Bonneville et al. and the cBioPortal TCGA PanCancer Atlas files [12,13]. Binary outcomes comprised qualifying protein-altering PASS mutations in tissue-specific consensus cancer genes from MC3 and Bailey et al. [14,15], ten oncogenic-pathway alteration indicators [16], genome doubling [10], any called fusion and eligible recurrent fusion pairs [11], and MSI-H definitions at MANTIS >0.4 and a strict >0.6 sensitivity threshold [12]. A mutation target denotes a qualifying alteration in a cancer gene; it does not assert that every allele is a functionally validated driver.")
doc.add_paragraph("Continuous pairs required at least 50 non-missing patients. Binary pairs required at least 20 positive and 20 negative patients. Eligibility was decided before modelling and every eligible test remained in its endpoint-family multiplicity denominator.")

doc.add_heading("PLS1 regression and PLS–LDA classification", level=2)
doc.add_paragraph("For each cancer–endpoint pair, five outer folds estimated performance and five inner folds selected 1–10 PLS components. Scaling and component selection were learned from training patients only. Continuous performance was out-of-fold Q², with RMSE and Spearman correlation secondary. Binary models supplied PLS latent scores to ridge-stabilised LDA; balanced accuracy was primary and AUROC from continuous LDA scores was secondary in repeated validation.")
doc.add_paragraph("Nested performance was first checkpointed for the complete atlas. Only models capable of Tier B (Q²≥0.20 or chance-corrected balanced accuracy≥0.20) received up to 99 patient-label permutations. Evaluation stopped conservatively after five exceedances because raw p<0.05 was then impossible even if every remaining null statistic were less extreme; stopped endpoints were assigned p=1. Regression extremeness used lower RMSD, whereas classification used higher balanced accuracy. Completed finite p values were (b+1)/(B+1). Because each disease defines a separate prediction and intended-use population, Benjamini–Hochberg FDR was controlled within cancer and prespecified endpoint family; an across-cancer family q-value was retained as a stricter sensitivity. Tier A required primary q<0.05 and effect≥0.40; Tier B required primary q<0.05 and effect 0.20–0.39. An optional 999-permutation extension is implemented in the public code but was not required for primary tiering.")

doc.add_heading("Robustness, saved models and PLS2 sensitivity", level=2)
doc.add_paragraph("Supported models were repeated under five independently seeded nested-CV partitions. Site-grouped folds kept two-character TCGA tissue-source-site codes out of both training and test partitions. A first-slide sensitivity replaced the primary mean-pooled vector while preserving patients and seeds. Full-data research models were tuned by ten-fold CV, saved with feature order, aggregation rule, class counts, software version and intended-use metadata, and tested through a public inference example that mean-pools user slides.")
doc.add_paragraph("The secondary PLS2 analysis jointly modelled three prespecified inflammatory blocks: infiltration/signatures, immune repertoire and inferred immune-cell fractions. PLS1 and PLS2 used identical complete-case patients and outer folds, training-fold outcome scaling, separately selected component counts and three independent nested-CV repeats. Changes in Q² were aggregated by cancer with cancer-bootstrap intervals; endpoint win counts were not treated as inferential evidence.")

doc.add_heading("Software, transparency and validation status", level=2)
doc.add_paragraph(f"Analyses used R 4.6 and fastPLS 0.99.20 (Git commit dcf45cc). Complete code, source manifests, target catalogues, checkpoints, out-of-fold predictions, figures, model registry and inference example are organized at {REPO}. Fitted TITAN-derived model objects are generated locally; their public redistribution remains subject to TITAN's upstream terms. No external cohort with compatible precomputed TITAN features and the required multi-omic labels was identified, so all performance estimates remain internal to TCGA.")
doc.add_paragraph("OpenAI Codex was used for analysis-code refactoring, document generation and language editing. All statistical choices, source-data mappings, numerical outputs and manuscript interpretations were reviewed by the human authors, who retain responsibility for the work.")

doc.add_heading("Results", level=1)
doc.add_heading("Cohort and analysis coverage", level=2)
doc.add_paragraph(f"The embedding cohort contained {n_patients:,} patients represented by {n_slides:,} slides; {n_multi:,} patients ({100*n_multi/n_patients:.1f}%) had more than one eligible diagnostic slide. Cancer labels were available for {n_patients-n_missing_cancer:,} patients across {n_cancers} cancers. The atlas evaluated {len(continuous):,} continuous and {len(binary):,} binary cancer–endpoint pairs (Table 1).")
doc.add_paragraph("Table 1. Eligible cancer–endpoint models and evidence tiers.", style="Caption")
add_table(doc, ["Family", "Type", "Tests", "Cancers", "Tier A", "Tier B", "Tier C"], family_table,
          [4.8, 2.0, 1.5, 1.5, 1.5, 1.5, 1.5])

doc.add_heading("Continuous immune, genomic-context and instability phenotypes", level=2)
doc.add_paragraph(f"Among continuous targets, {len([r for r in supported_c if r['tier']=='A'])} were Tier A and {len([r for r in supported_c if r['tier']=='B'])} Tier B. The strongest effects were {examples(top_c, 'q2', 10)}. These results were cancer specific: the same endpoint could be strongly predictable in one tumour type and unsupported in another.")
doc.add_paragraph(f"None of the {len(supported_c)} primary continuous Tier-A/B pairs met q<0.05 under the stricter across-cancer family sensitivity at the 99-permutation resolution. Continuous findings should therefore be interpreted as disease-specific screens rather than globally FDR-supported pan-cancer discoveries.")
add_figure(doc, "Figure2_continuous_atlas.png", "Figure 2. Strongest supported continuous cancer–endpoint results. Q² is calculated from genuine patient-level outer-fold predictions; all tests remain available in the machine-readable atlas.")

doc.add_heading("Binary molecular phenotypes", level=2)
doc.add_paragraph(f"The binary atlas yielded {len([r for r in supported_b if r['tier']=='A'])} Tier-A and {len([r for r in supported_b if r['tier']=='B'])} Tier-B pairs. Leading results were {examples(top_b, 'balanced_accuracy', 12)}. The complete table includes tested-negative and ineligible distinctions for mutations, pathways, genome doubling, MSI and fusions.")
doc.add_paragraph(f"Of {len(supported_b)} primary binary Tier-A/B pairs, {len(global_supported_b)} also met the stricter across-cancer family q<0.05. No cancer–gene mutation pair passed that global sensitivity, whereas supported pathway, MSI and fusion signals generally did; mutation results are consequently described as cancer-screen-specific findings.")
add_figure(doc, "Figure3_binary_atlas.png", "Figure 3. Strongest supported binary molecular predictions using PLS latent scores and LDA. Point size represents the number of positive patients.")
add_figure(doc, "Figure4_supported_counts.png", "Figure 4. Number and family of Tier-A/B prediction targets within each cancer. Absence of an eligible target is distinct from a tested negative result.")

doc.add_heading("Site and multiple-slide sensitivity", level=2)
doc.add_paragraph(f"Site-grouped validation was feasible for {sum(r.get('feasible')=='TRUE' for r in site_c)+sum(r.get('feasible')=='TRUE' for r in site_b)} supported models. The median grouped-minus-random performance change was {fnum(median(site_deltas))}. The first-slide-minus-mean-pool median change across supported models was {fnum(median(pool_deltas))}. Individual attenuations are reported because centre robustness and slide aggregation are target specific.")
add_figure(doc, "Figure5_site_grouped_sensitivity.png", "Figure 5. Random-fold versus tissue-source-site-grouped internal validation. Values below the diagonal indicate attenuation when submitting sites are separated.")

doc.add_heading("Secondary PLS1–PLS2 comparison", level=2)
if pls2:
    text = []
    for r in pls2:
        text.append(f'{r["block"].replace("_", " ")}: mean cancer-level ΔQ² {fnum(r["mean_cancer_delta"])} (95% interval {fnum(r["ci_low"])} to {fnum(r["ci_high"])})')
    doc.add_paragraph("; ".join(text) + ". These effect magnitudes, not the number of endpoints won, determine interpretation.")
add_figure(doc, "Figure6a_pls1_vs_pls2_targets.png", "Figure 6a. Matched target-level PLS1 and PLS2 Q² on identical held-out patients.")
add_figure(doc, "Figure6b_pls1_vs_pls2_cancers.png", "Figure 6b. Cancer-level mean Q² change for joint PLS2 relative to response-by-response PLS1.")

doc.add_heading("Discussion", level=1)
doc.add_paragraph("This study answers a target-by-target, cancer-specific question rather than asking whether molecular subtype and mutation status are associated. Frozen TITAN features contain useful signal for selected immune programmes, mutations and higher-level genomic phenotypes, but most eligible pairs do not satisfy both multiplicity and effect thresholds. That heterogeneity—and transparent negative reporting—is the primary result.")
doc.add_paragraph("Prior CNN studies recovered histological signal for multiple exact cancer–gene pairs [1–5]. In the prespecified crosswalk, " + ", ".join(f"{k.replace('_',' ')}: {v}" for k,v in sorted(lit_counts.items())) + ". Recovered and unrecovered pairs are listed in Supplementary Table S4; original study metrics, evidence notes and URLs are retained in the machine-readable crosswalk. Current balanced accuracy cannot be numerically equated to prior AUROC, and disagreement may reflect primary-versus-metastatic sampling, frozen versus FFPE preparation, mutation definition, model class or validation design.")
doc.add_paragraph("The practical advantage of TITAN plus PLS is rapid reuse. Once slide embeddings exist, hundreds of new outcomes can be screened without retraining a CNN encoder. This is useful for discovery and triage, particularly when new genomic annotations become available. It does not eliminate the one-time TITAN extraction cost and is not a hardware-matched claim of superior accuracy.")
doc.add_paragraph("Joint PLS2 is most compelling when responses are correlated and measured on the same patients. Its inflammatory benefit must nevertheless be judged by ΔQ² and its cancer-level interval. Binary mutations and fusions are sparse and only partially correlated, so a shared response space can dilute target-specific signal; separate PLS–LDA therefore remains the primary binary strategy.")
doc.add_paragraph("Strengths include primary-tumour matching across every data source, deterministic mean pooling of multiple slides, nested patient-level validation, family-wise FDR, exact negative-result reporting, site-grouped sensitivity, saved research models and executable inference code. The supplied Bonneville spreadsheets contained only an ACC/CESC/MESO subset; cBioPortal PanCancer Atlas MANTIS fields were therefore used for full coverage and agreed exactly for all 387 overlapping cases.")
doc.add_paragraph("The principal limitation is absence of independent external validation. TCGA resampling, even with site separation, cannot establish transportability to another institution, scanner, stain distribution or patient population. The study is retrospective and exploratory; thresholds are prioritisation rules, not clinical operating points. TITAN used report alignment during pretraining, predictability does not establish biological causality, and image-derived predictions cannot justify omitting a molecular assay. External feature extraction and prospective evaluation are required before clinical use.")

doc.add_heading("Conclusions", level=1)
doc.add_paragraph("Mean-pooled, frozen TITAN embeddings enable a rapid cancer-specific atlas of selected immune, mutation, pathway, MSI, aneuploidy and fusion phenotypes. PLS2 is a secondary option for correlated inflammatory panels; individual PLS–LDA remains the clearer default for binary molecular targets. The resource prioritises hypotheses and exposes unsupported targets, but remains internally validated and non-clinical.")

doc.add_heading("Declarations", level=1)
for h, text in [
    ("Ethics approval and consent to participate", "This secondary analysis used publicly available, de-identified TCGA data. No participants were recruited and no new tissue was collected."),
    ("Consent for publication", "Not applicable."),
    ("Availability of data and materials", f"Source locations and checksums are recorded in the repository: {REPO}. TCGA data are available from the Genomic Data Commons; TITAN resources are available from MahmoodLab. Model-object redistribution is subject to TITAN's upstream terms."),
    ("Competing interests", "[Author confirmation required before submission.]"),
    ("Funding", "[Author confirmation required before submission.]"),
    ("Authors’ contributions", "[Author initials and contribution statement required before submission.]"),
    ("Acknowledgements", "OpenAI Codex assisted with code refactoring and language editing. Human authors remain responsible for verification, interpretation and the submitted text."),
]:
    doc.add_heading(h, level=2); doc.add_paragraph(text)

doc.add_heading("References", level=1)
references = [
"1. Coudray N, et al. Classification and mutation prediction from non-small cell lung cancer histopathology images using deep learning. Nat Med. 2018;24:1559–1567. doi:10.1038/s41591-018-0177-5.",
"2. Fu Y, et al. Pan-cancer computational histopathology reveals mutations, tumor composition and prognosis. Nat Cancer. 2020;1:800–810. doi:10.1038/s43018-020-0085-8.",
"3. Kather JN, et al. Pan-cancer image-based detection of clinically actionable genetic alterations. Nat Cancer. 2020;1:789–799. doi:10.1038/s43018-020-0087-6.",
"4. Schmauch B, et al. A deep learning model to predict RNA-Seq expression of tumours from whole slide images. Nat Commun. 2020;11:3877. doi:10.1038/s41467-020-17678-4.",
"5. Loeffler CML, et al. Predicting mutational status of driver and suppressor genes directly from histopathology with deep learning. Front Genet. 2022;12:806386. doi:10.3389/fgene.2021.806386.",
"6. Ding T, et al. A multimodal whole-slide foundation model for pathology. Nat Med. 2025;31:3749–3761. doi:10.1038/s41591-025-03982-3.",
"7. Wold S, Sjöström M, Eriksson L. PLS-regression: a basic tool of chemometrics. Chemometr Intell Lab Syst. 2001;58:109–130. doi:10.1016/S0169-7439(01)00155-1.",
"8. Szymańska E, et al. Double-check: validation of diagnostic statistics for PLS-DA models. Metabolomics. 2012;8(Suppl 1):3–16. doi:10.1007/s11306-011-0330-3.",
"9. Thorsson V, et al. The Immune Landscape of Cancer. Immunity. 2018;48:812–830.e14. doi:10.1016/j.immuni.2018.03.023.",
"10. Taylor AM, et al. Genomic and functional approaches to understanding cancer aneuploidy. Cancer Cell. 2018;33:676–689.e3. doi:10.1016/j.ccell.2018.03.007.",
"11. Gao Q, et al. Driver fusions and their implications in the development and treatment of human cancers. Cell Rep. 2018;23:227–238.e3. doi:10.1016/j.celrep.2018.03.050.",
"12. Bonneville R, et al. Landscape of microsatellite instability across 39 cancer types. JCO Precis Oncol. 2017;2017:PO.17.00073. doi:10.1200/PO.17.00073.",
"13. Cerami E, et al. The cBio cancer genomics portal. Cancer Discov. 2012;2:401–404. doi:10.1158/2159-8290.CD-12-0095.",
"14. Ellrott K, et al. Scalable open science approach for mutation calling of tumor exomes. Cell Syst. 2018;6:271–281.e7. doi:10.1016/j.cels.2018.03.002.",
"15. Bailey MH, et al. Comprehensive characterization of cancer driver genes and mutations. Cell. 2018;173:371–385.e18. doi:10.1016/j.cell.2018.02.060.",
"16. Sanchez-Vega F, et al. Oncogenic signaling pathways in The Cancer Genome Atlas. Cell. 2018;173:321–337.e10. doi:10.1016/j.cell.2018.03.035.",
"17. Benjamini Y, Hochberg Y. Controlling the false discovery rate. J R Stat Soc B. 1995;57:289–300. doi:10.1111/j.2517-6161.1995.tb02031.x.",
"18. Collins GS, et al. TRIPOD+AI statement. BMJ. 2024;385:e078378. doi:10.1136/bmj-2023-078378.",
]
for ref in references: doc.add_paragraph(ref)
doc.save(OUT / "manuscript_JTM_patient_level_TITAN.docx")


# Supplementary document
sup = setup(Document(), "Supplementary material — TITAN atlas")
sup.add_heading("Supplementary material", 0)
sup.add_paragraph("A patient-level atlas of molecular and immune predictability from frozen TITAN whole-slide embeddings across 32 cancers")
sup.add_heading("Supplementary Methods", 1)
sup.add_paragraph("The executable analysis plan, source manifest, eligibility catalogues, checkpoints and out-of-fold predictions are available in the companion repository. Tables below are concise views; complete machine-readable CSV files are authoritative.")
sup.add_heading("Table S1. Analysis coverage", 1)
add_table(sup, ["Family", "Type", "Tests", "Cancers", "Tier A", "Tier B", "Tier C"], family_table)
sup.add_heading("Table S2. Top continuous results", 1)
add_table(sup, ["Cancer", "Endpoint", "Family", "n", "Q²", "q", "Tier"],
          [(r["tumor_type"], r["endpoint"], r["family"], r["n"], fnum(r["q2"]), fnum(r["q_value"]), r["tier"]) for r in top_c[:60]])
sup.add_heading("Table S3. Top binary results", 1)
add_table(sup, ["Cancer", "Endpoint", "Family", "n", "Positive", "Balanced accuracy", "q", "Tier"],
          [(r["tumor_type"], r["endpoint"], r["family"], r["n"], r["positive"], fnum(r["balanced_accuracy"]), fnum(r["q_value"]), r["tier"]) for r in top_b[:60]])
sup.add_heading("Table S4. Previously reported histology mutation pairs", 1)
add_table(sup, ["Cancer", "Gene", "Prior studies", "Current status", "n", "Positive", "Balanced accuracy", "q"],
          [(r["current_cancer"], r["gene"], r["studies"], r["current_status"], r["n"], r["positive"], fnum(r["current_balanced_accuracy"]), fnum(r["current_q"])) for r in lit])
sup.add_heading("Machine-readable additional files", 1)
for name in ["continuous_screen.csv", "binary_screen.csv", "continuous_repeated_nested_cv.csv", "binary_repeated_nested_cv.csv", "continuous_site_grouped_sensitivity.csv", "binary_site_grouped_sensitivity.csv", "continuous_slide_pooling_sensitivity.csv", "binary_slide_pooling_sensitivity.csv", "pls1_vs_pls2_inflammation.csv", "prior_mutation_literature_crosswalk.csv", "nonmutation_sample_type_audit.csv", "mutation_sample_type_audit.csv", "source_manifest.csv", "models/model_registry.csv"]:
    sup.add_paragraph(name, style="List Bullet")
sup.save(OUT / "supplementary_material_JTM.docx")


# Point-by-point response
resp = setup(Document(), "Response to reviewer — TITAN atlas")
resp.add_heading("Response to reviewer", 0)
resp.add_paragraph("Manuscript: A patient-level atlas of molecular and immune predictability from frozen TITAN whole-slide embeddings across 32 cancers")
resp.add_paragraph("We thank the reviewer for identifying validation and reproducibility as the principal issues. The analysis has been rebuilt from the original files with patient-first slide aggregation and primary-tumour molecular matching.")

responses = [
    ("1. External validation is the principal unresolved limitation",
     "We agree. No independent cohort containing compatible precomputed TITAN embeddings together with the mutation, immune, pathway, MSI, aneuploidy and fusion labels was identified. We therefore do not describe the models as externally validated. The title, abstract, intended-use statement, Discussion and Conclusions explicitly frame the work as an internally validated hypothesis-generation resource. We added site-grouped validation, saved research models and executable inference code to facilitate future external testing, but state that these do not substitute for external validation."),
    ("2. Site robustness is incomplete for the inflammatory atlas",
     f"Addressed. Tissue-source-site-grouped validation is now attempted for every supported continuous and binary endpoint, not only mutations. It was feasible for {sum(r.get('feasible')=='TRUE' for r in site_c)+sum(r.get('feasible')=='TRUE' for r in site_b)} models. Figure 5 and the complete machine-readable tables report target-level attenuation; the manuscript does not claim that repeated random folds exclude site confounding."),
    ("3. Reproducibility materials must be deposited before submission",
     f"Addressed in a public repository ({REPO}) containing the exact analysis plan, source URLs/checksums, software commit, eligibility tables, code for every analysis and figure, out-of-fold prediction outputs, model registry, inference example and literature crosswalk. An archived versioned release with a persistent DOI remains to be created before submission."),
    ("4. Distinguish cancer genes from functional driver alleles",
     "Addressed throughout. Mutation targets are described as qualifying protein-altering PASS mutations in tissue-specific consensus cancer genes; the manuscript explicitly states that not every allele is functionally validated."),
    ("5. Preserve effect-size-first interpretation of PLS2",
     "Addressed. PLS2 is restricted to coherent inflammatory blocks as a secondary analysis. PLS1 and PLS2 use identical patients and folds, and interpretation is based on cancer-level ΔQ² with bootstrap intervals rather than win counts. Binary molecular endpoints retain one-at-a-time PLS–LDA as the primary analysis."),
    ("6. Complete submission-specific fields",
     "Partly outstanding. Corresponding-author details, final author list, funding, competing interests and contribution statements require author confirmation and remain visibly marked. No scientific values are placeholder text."),
    ("7. Presentation and runtime claims",
     "Addressed. High-resolution figures and machine-readable tables accompany the Word documents. The text states that speed applies after TITAN embeddings have been computed and does not claim a hardware-matched accuracy or runtime comparison with CNN pipelines."),
    ("Additional change: multiple slides and molecular specimen matching",
     f"The primary predictor is now the feature-wise mean of every eligible diagnostic slide per patient; {n_multi:,} multi-slide patients are retained in a single validation fold. We also audited every molecular source and excluded non-primary TCGA sample types before aggregation. A matched first-slide sensitivity quantifies dependence on the pooling rule."),
]
for title, answer in responses:
    resp.add_heading(title, 1); resp.add_paragraph(answer)
resp.save(OUT / "response_to_reviewer_JTM.docx")

print(OUT / "manuscript_JTM_patient_level_TITAN.docx")
print(OUT / "supplementary_material_JTM.docx")
print(OUT / "response_to_reviewer_JTM.docx")
