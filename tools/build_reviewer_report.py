from pathlib import Path

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "manuscript" / "reviewer_report_JTM.docx"

BLUE = RGBColor(46, 116, 181)
DARK_BLUE = RGBColor(31, 77, 120)
MUTED = RGBColor(90, 90, 90)
BLACK = RGBColor(0, 0, 0)


def set_cell_shading(paragraph, fill):
    ppr = paragraph._p.get_or_add_pPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:fill"), fill)
    ppr.append(shd)


def set_font(run, size=11, bold=False, italic=False, color=BLACK):
    run.font.name = "Calibri"
    run._element.get_or_add_rPr().rFonts.set(qn("w:ascii"), "Calibri")
    run._element.get_or_add_rPr().rFonts.set(qn("w:hAnsi"), "Calibri")
    run.font.size = Pt(size)
    run.bold = bold
    run.italic = italic
    run.font.color.rgb = color


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


def add_body(doc, text, bold_lead=None):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(0)
    p.paragraph_format.space_after = Pt(6)
    p.paragraph_format.line_spacing = 1.10
    if bold_lead and text.startswith(bold_lead):
        lead = p.add_run(bold_lead)
        set_font(lead, bold=True)
        body = p.add_run(text[len(bold_lead):])
        set_font(body)
    else:
        set_font(p.add_run(text))
    return p


def add_heading(doc, text, level=1):
    p = doc.add_paragraph(style=f"Heading {level}")
    p.paragraph_format.keep_with_next = True
    p.add_run(text)
    return p


def add_comment(doc, number, title, assessment, revision):
    add_heading(doc, f"{number}. {title}", 2)
    add_body(doc, assessment)
    add_body(doc, f"Required revision: {revision}", bold_lead="Required revision:")


doc = Document()
section = doc.sections[0]
section.page_width = Inches(8.5)
section.page_height = Inches(11)
section.top_margin = Inches(1)
section.bottom_margin = Inches(1)
section.left_margin = Inches(1)
section.right_margin = Inches(1)
section.header_distance = Inches(0.492)
section.footer_distance = Inches(0.492)

styles = doc.styles
normal = styles["Normal"]
normal.font.name = "Calibri"
normal._element.rPr.rFonts.set(qn("w:ascii"), "Calibri")
normal._element.rPr.rFonts.set(qn("w:hAnsi"), "Calibri")
normal.font.size = Pt(11)
normal.paragraph_format.space_after = Pt(6)
normal.paragraph_format.line_spacing = 1.10

for name, size, color, before, after in (
    ("Heading 1", 16, BLUE, 16, 8),
    ("Heading 2", 13, BLUE, 12, 6),
    ("Heading 3", 12, DARK_BLUE, 8, 4),
):
    style = styles[name]
    style.font.name = "Calibri"
    style._element.rPr.rFonts.set(qn("w:ascii"), "Calibri")
    style._element.rPr.rFonts.set(qn("w:hAnsi"), "Calibri")
    style.font.size = Pt(size)
    style.font.bold = True
    style.font.color.rgb = color
    style.paragraph_format.space_before = Pt(before)
    style.paragraph_format.space_after = Pt(after)
    style.paragraph_format.keep_with_next = True

header = section.header.paragraphs[0]
header.alignment = WD_ALIGN_PARAGRAPH.LEFT
header.paragraph_format.space_after = Pt(0)
set_font(header.add_run("Journal-style internal peer review | TITAN prediction atlas"), size=9, color=MUTED)

footer = section.footer.paragraphs[0]
footer.alignment = WD_ALIGN_PARAGRAPH.RIGHT
footer.paragraph_format.space_after = Pt(0)
set_font(footer.add_run("Page "), size=9, color=MUTED)
add_page_field(footer)

title = doc.add_paragraph()
title.paragraph_format.space_before = Pt(14)
title.paragraph_format.space_after = Pt(4)
set_font(title.add_run("REVIEWER REPORT"), size=23, bold=True)

subtitle = doc.add_paragraph()
subtitle.paragraph_format.space_after = Pt(16)
set_font(
    subtitle.add_run(
        "A patient-level atlas of molecular and immune predictability from frozen TITAN whole-slide embeddings across 32 cancers"
    ),
    size=14,
    color=MUTED,
)

for label, value in (
    ("Target journal", "Journal of Translational Medicine — Molecular Pathology"),
    ("Article type", "Research article"),
    ("Assessment", "Journal-style internal review; not an invited journal review"),
    ("Recommendation", "Major revision"),
    ("Date", "15 August 2026"),
):
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(2)
    set_font(p.add_run(f"{label}: "), bold=True)
    set_font(p.add_run(value))

callout = doc.add_paragraph()
callout.paragraph_format.space_before = Pt(14)
callout.paragraph_format.space_after = Pt(10)
callout.paragraph_format.left_indent = Inches(0.12)
callout.paragraph_format.right_indent = Inches(0.12)
set_cell_shading(callout, "F2F4F7")
set_font(callout.add_run("Overall assessment. "), bold=True, color=DARK_BLUE)
set_font(
    callout.add_run(
        "The manuscript is potentially suitable for the Molecular Pathology section and the patient-first reanalysis is substantially stronger than a slide-level screen. Its principal value is a transparent cancer-specific atlas, including negative results. However, the present evidence does not yet support the strength of the terms ‘supported’ and ‘predictable’ across the atlas. The multiplicity strategy, permutation resolution, model-selection stability, absence of an external cohort, and lack of a measured speed/benchmark comparison require major revision before the translational claims are persuasive."
    )
)

add_heading(doc, "Confidential comments to the editor", 1)
add_body(
    doc,
    "The topic fits the journal’s Molecular Pathology remit because it applies a computational platform to molecular profiling of human tumour tissue. The study is broad, reproducible, and scientifically interesting. The cancer-specific framing and explicit distinction between unsupported and ineligible endpoints are important strengths. I would not reject the work on concept alone. Nevertheless, the current manuscript is best regarded as an internally validated discovery resource rather than a translational prediction study. I recommend major revision, with particular emphasis on more stable inferential testing, repeated validation of the discovery set, a measured computational benchmark, and either external validation or substantially narrower claims."
)
add_body(
    doc,
    "If the journal requires evidence of transportability for predictive-model papers, the lack of any independent cohort may remain an editorial limitation after revision. A pre-submission enquiry to the Molecular Pathology editor would therefore be reasonable."
)

add_heading(doc, "Major comments to the authors", 1)

add_comment(
    doc,
    1,
    "Multiplicity and permutation resolution are not adequate for the headline atlas claims",
    "The primary Benjamini–Hochberg correction is performed separately within each cancer and endpoint family. This is defensible for a collection of disease-specific screens, but the manuscript’s headline is a 32-cancer atlas and it repeatedly totals discoveries across all cancers. Under the stricter across-cancer family correction, none of the 152 continuous Tier A/B results remains significant, and no mutation pair passes the global sensitivity. With only 99 completed permutations, the attainable p-values are coarse and q-values near 0.05 are unstable.",
    "Run the implemented 999-permutation extension for every endpoint capable of entering Tier A or B, report Monte Carlo resolution and the number stopped early, and present the across-cancer family correction alongside the within-cancer correction in the main result tables and figures. Either use a hierarchical/global procedure for atlas-wide claims or consistently describe within-cancer findings as exploratory candidates rather than discoveries."
)

add_comment(
    doc,
    2,
    "Tier assignment relies on one nested-CV partition, while repeats are post-selection",
    "The screen uses one five-outer-by-five-inner nested split. Five additional nested-CV repeats are then run only for endpoints already selected as Tier A/B. This demonstrates sensitivity of selected models to partitioning, but it does not remove winner’s curse or show how often all candidate endpoints would be selected. The phrase ‘nested 5×5 cross-validation’ may also be misread as 25 repeated outer evaluations rather than five outer folds with five-fold inner tuning.",
    "State the design unambiguously. Re-evaluate at least all effect-eligible endpoints across repeated nested partitions and base the main effect estimate or tier on a prespecified aggregate across repeats. Report variation intervals and tier stability. If computational constraints prevent this, label the tiers as single-partition screening tiers and move the repeated estimates into the principal evidence for each highlighted endpoint."
)

add_comment(
    doc,
    3,
    "External validation and translational positioning",
    "All model development, selection, permutation testing, site sensitivity, and final fitting use TCGA. Tissue-source-site grouping is valuable but cannot establish transportability to another scanner, laboratory, stain distribution, tissue preparation, or patient population. The manuscript acknowledges this, yet terms such as ‘predictable,’ ‘supported models,’ and the emphasis on external reuse can still be interpreted as validated clinical prediction.",
    "Add an independent cohort if compatible slides and outcomes can be obtained. Otherwise recast the paper consistently as a discovery atlas and model-development resource, avoid diagnostic language, place ‘internal validation only’ in the abstract Results and Conclusions, and define a concrete external-validation protocol as the next required stage."
)

add_comment(
    doc,
    4,
    "The claimed advantage of speed is not directly demonstrated",
    "The Introduction and Discussion identify rapid reuse as the main advantage over task-specific CNNs, but no wall-clock time, hardware use, memory use, or comparator benchmark is reported. Once embeddings exist, PLS is plausibly fast, but the one-time TITAN extraction cost is substantial and should not be separated from the intended deployment workflow without measurements.",
    "Provide a reproducible runtime benchmark for representative continuous and binary targets and for the complete screening stage, including hardware, number of patients, number of endpoints, permutations, and peak memory. Separate embedding-extraction cost from downstream model fitting. A simple comparator such as elastic-net regression/logistic regression should be included to establish whether PLS offers a useful accuracy–speed trade-off rather than speed alone."
)

add_comment(
    doc,
    5,
    "Clarify overlap between TITAN pretraining and the downstream TCGA cohort",
    "TITAN was pretrained on a very large collection and used report alignment. The manuscript should state explicitly whether the TCGA slides analysed here were part of TITAN pretraining and whether their reports or identifiers contributed to vision–language alignment. This is not necessarily outcome leakage, because the downstream labels differ, but it changes the interpretation from fully independent transfer to reuse on potentially seen images.",
    "Document the relationship between the pretraining corpus and the 11,449 analysed slides using the TITAN paper and released metadata. Explain why no tested molecular or immune labels entered pretraining, if that can be established, and discuss the remaining risk of representation advantage on pretraining images."
)

add_comment(
    doc,
    6,
    "Outcome construction, missingness, and multiple specimens need a fuller audit trail",
    "The patient-level mean of multiple eligible slides is appropriate and the first-slide sensitivity is reassuring. However, readers need to know how many slides each patient contributed by cancer, whether slides represent separate blocks or repeated scans, and how multiple molecular aliquots were collapsed. For mutations and fusions, absence of a call must be distinguished from absence of assay coverage or a missing profile. Fusion burden can also reflect RNA quality and calling opportunity.",
    "Add a cohort flow diagram and cancer-level table with patient counts, slide counts, multi-slide counts, endpoint coverage, and positive counts. Specify patient-level aggregation rules for every molecular source, how discordant aliquots were handled, how wild type was separated from missing, and what quality/coverage filters were required. Consider median pooling or a second deterministic slide aggregation as an additional sensitivity for endpoints with the largest first-slide attenuation."
)

add_comment(
    doc,
    7,
    "Prediction performance and external-use metadata are incomplete",
    "Balanced accuracy is reasonable for imbalanced binary endpoints, but the main manuscript does not provide sensitivity, specificity, AUROC intervals, calibration, or decision thresholds. Full-data LDA models can be applied externally only if feature order, TITAN version, preprocessing, slide aggregation, class coding, class priors, and threshold behaviour are frozen and documented. For continuous endpoints, Q² alone does not show scale-specific error or uncertainty.",
    "For highlighted models, report out-of-fold sensitivity, specificity, AUROC, balanced accuracy, and uncertainty; report RMSE and Spearman correlation for continuous targets. Add input validation, training ranges or an out-of-distribution warning, class coding, and threshold metadata to the model artefacts. Make clear that the released objects are research models and that their distribution depends on upstream licence permission."
)

add_comment(
    doc,
    8,
    "The PLS2 analysis is promising but requires more transparent denominators",
    "The matched complete-case comparison is methodologically sensible, and cancer-level aggregation is preferable to endpoint win counts. Nevertheless, each block can use a different subset of patients and endpoints, and the current text gives only three mean differences and bootstrap intervals. The number of cancers, endpoints, and patients contributing to each estimate is not visible in the main manuscript.",
    "Report the endpoint composition, number of evaluable cancers, patient-size range, number of endpoints per cancer, PLS1 and PLS2 component distributions, and cancer-level paired results. Explain the bootstrap resampling unit and provide a sensitivity weighted by cancer sample size or precision while retaining the unweighted cancer analysis as primary."
)

add_comment(
    doc,
    9,
    "Several results are presented in ways that can mislead readers",
    "The Abstract lists continuous and binary values without naming Q² and balanced accuracy. In the binary Results, LGG–TP53 appears twice because one row is a gene mutation and the other a pathway alteration, but the family is omitted. The term ‘Tier C’ combines nonsignificant and small-effect results, while ‘supported’ may imply external confirmation. The top-result lists also invite ranking by a single split without uncertainty.",
    "Label every metric in the Abstract and main text, disambiguate mutation and pathway endpoints, define Tier C precisely, and use ‘screen-positive candidate’ or similarly cautious wording. Add uncertainty or repeated-CV summaries to highlighted results and include global q-values in the main tables."
)

add_comment(
    doc,
    10,
    "Reproducibility claims must match what can actually be released",
    "The repository structure, source manifest, target catalogues, out-of-fold predictions, saved-model registry, and inference example are major strengths. At present, however, the manuscript contains a placeholder repository URL and model binaries cannot be redistributed until the TITAN licence position is resolved. A registry of hashes is not a substitute for downloadable model objects for external users.",
    "Publish the repository before submission, replace every placeholder URL with a permanent link, archive a versioned release with a DOI if possible, and state exactly which files are public. Obtain written permission before releasing model objects; if permission is not obtained, provide a deterministic script that recreates each model from legitimately obtained TITAN features and avoid claiming that pretrained models are downloadable."
)

add_heading(doc, "Minor comments", 1)

minor = [
    ("Title terminology", "‘Frozen TITAN embeddings’ may be confused with frozen-section tissue. Consider ‘fixed pretrained TITAN whole-slide embeddings’ or ‘frozen-encoder TITAN embeddings.’"),
    ("Abstract metrics", "Write ‘Q²=…’ for continuous results and ‘balanced accuracy=…’ for binary results; state that validation is internal."),
    ("Duplicate endpoint names", "Use labels such as ‘LGG–TP53 mutation’ and ‘LGG–TP53 pathway alteration’ throughout figures, captions, and prose."),
    ("Tier nomenclature", "State that thresholds are prioritisation rules, not established clinical grades, and report the number of endpoints that are ineligible separately from tested-negative endpoints."),
    ("Feature provenance", "Specify the TITAN checkpoint, embedding layer, dimensionality, slide preprocessing, and exact feature-file version/checksum."),
    ("Site sensitivity", "Report the number of tissue-source sites and class counts per grouped fold for highlighted binary endpoints, including any infeasible models."),
    ("Figures", "Use consistent family colours and ensure point legends distinguish mutation, pathway, fusion, MSI, and aneuploidy results. Include n and positive counts in an accessible supplementary table."),
    ("MSI terminology", "Explain why MANTIS >0.4 is primary and >0.6 is sensitivity, and avoid presenting the two correlated definitions as independent evidence."),
    ("Fusion interpretation", "Discuss technical detection variability and avoid assuming ‘any called fusion’ is a single biological phenotype."),
    ("Administrative completion", "Author list, corresponding author, funding, competing interests, contributions, ethics wording, and repository URL must be completed before submission."),
    ("Reporting guidance", "Use TRIPOD+AI as an explicit reporting checklist and provide the completed checklist as a submission supplement."),
]
for title_text, body_text in minor:
    add_heading(doc, title_text, 3)
    add_body(doc, body_text)

add_heading(doc, "Strengths that should be retained", 1)
for title_text, body_text in (
    ("Patient-first design", "All eligible slides are aggregated before outcome matching and cross-validation, preventing slide-level leakage."),
    ("Cancer-specific question", "The manuscript correctly asks which endpoints are predictable within each cancer rather than exploiting pan-cancer morphology."),
    ("Broad outcome coverage", "Mutations, pathways, inflammatory features, fusions, MSI, aneuploidy, and genome doubling are included with explicit eligibility rules."),
    ("Transparent negative results", "The complete target catalogue distinguishes tested-negative, unsupported, and ineligible endpoints."),
    ("Appropriate PLS2 positioning", "PLS2 is secondary and restricted to coherent inflammatory response blocks; binary endpoints retain PLS–LDA."),
    ("Reproducible implementation", "Code, manifests, out-of-fold predictions, model metadata, tests, and an inference example are organised for audit."),
):
    add_heading(doc, title_text, 3)
    add_body(doc, body_text)

add_heading(doc, "Recommended editorial decision", 1)
decision = doc.add_paragraph()
decision.paragraph_format.space_before = Pt(0)
decision.paragraph_format.space_after = Pt(8)
decision.paragraph_format.line_spacing = 1.10
set_cell_shading(decision, "E8EEF5")
set_font(decision.add_run("MAJOR REVISION"), size=12, bold=True, color=DARK_BLUE)
add_body(
    doc,
    "The manuscript has a publishable core, but its principal claims should not be accepted in their current form. The minimum revision should include higher-resolution permutation testing, a more stable repeated-validation basis for highlighted endpoints, a formal runtime/comparator benchmark, explicit pretraining-overlap documentation, complete model-performance reporting, and a public versioned repository. External validation would materially strengthen the work and may be required by the editor for a predictive-model article."
)

add_heading(doc, "Sources used for journal-fit assessment", 1)
add_body(
    doc,
    "Journal of Translational Medicine, Molecular Pathology section editorial: Warren S. Molecular Pathology. J Transl Med. 2024;22:91. https://doi.org/10.1186/s12967-024-04868-7"
)
add_body(
    doc,
    "Collins GS, et al. TRIPOD+AI statement. BMJ. 2024;385:e078378. https://doi.org/10.1136/bmj-2023-078378"
)

doc.core_properties.title = "Reviewer report — TITAN patient-level prediction atlas"
doc.core_properties.subject = "Journal-style internal peer review for Journal of Translational Medicine"
doc.core_properties.author = "Internal scientific review"
doc.core_properties.keywords = "TITAN; computational pathology; peer review; Journal of Translational Medicine"

OUTPUT.parent.mkdir(parents=True, exist_ok=True)
doc.save(OUTPUT)
print(OUTPUT)
