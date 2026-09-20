#!/usr/bin/env python3
"""Build the two complete three-representation PathoFMPred example reports."""

from __future__ import annotations

import csv
import html
from datetime import date
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import landscape, letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (
    KeepTogether,
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)


ROOT = Path(__file__).resolve().parents[1]
TABLE_DIR = ROOT / "results" / "tables"
REPORT_DIR = ROOT / "results" / "reports"

MODEL_ORDER = ("TITAN", "GigaSSL", "ProvGigaPath")
MODEL_LABEL = {
    "TITAN": "TITAN",
    "GigaSSL": "Giga-SSL",
    "ProvGigaPath": "Prov-GigaPath",
}
MODEL_COLOUR = {
    "TITAN": colors.HexColor("#2F6DA1"),
    "GigaSSL": colors.HexColor("#E68613"),
    "ProvGigaPath": colors.HexColor("#2A9D8F"),
}
NAVY = colors.HexColor("#17365D")
MUTED = colors.HexColor("#526579")
LIGHT_BLUE = colors.HexColor("#EAF1F7")
LIGHT_GREY = colors.HexColor("#F3F5F7")
WARNING_BG = colors.HexColor("#FFF3CD")
WARNING_BORDER = colors.HexColor("#C99700")
POSITIVE_BG = colors.HexColor("#F9DDD8")
NEGATIVE_BG = colors.HexColor("#E3EEF7")


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def esc(value: object) -> str:
    text = "" if value is None else str(value)
    return html.escape(text.replace("\u2013", "-").replace("\u2014", "-"))


def number(value: str | None, digits: int = 3) -> str:
    try:
        numeric = float(value or "")
    except (TypeError, ValueError):
        return "NA"
    rendered = f"{numeric:.{digits}f}"
    return rendered.rstrip("0").rstrip(".") if "." in rendered else rendered


def prediction_value(value: str | None) -> str:
    try:
        numeric = float(value or "")
    except (TypeError, ValueError):
        return "NA"
    if abs(numeric) < 0.0001 and numeric != 0:
        return f"{numeric:.4e}"
    return f"{numeric:.6f}".rstrip("0").rstrip(".")


def family_label(family: str) -> str:
    return {
        "aneuploidy": "Aneuploidy",
        "driver_mutation": "Mutation",
        "microsatellite_instability": "MSI",
        "microsatellite_instability_sensitivity": "MSI sensitivity",
        "oncogenic_pathway": "Pathway",
        "thorsson": "Immune/context",
    }.get(family, family.replace("_", " ").title())


def binary_call(row: dict[str, str]) -> str:
    positive = str(row.get("predicted_class", "")).strip() == "1"
    family = row.get("family", "")
    if family == "driver_mutation":
        return "Mutation" if positive else "Wild type"
    if family in {
        "microsatellite_instability",
        "microsatellite_instability_sensitivity",
    }:
        return "MSI-H" if positive else "Not MSI-H"
    if family == "aneuploidy":
        return "Present" if positive else "Absent"
    return "Altered" if positive else "Not altered"


def warning_label(row: dict[str, str]) -> str:
    status = (row.get("site_robustness_status") or "").strip()
    if not status:
        return "No recorded warning"
    if status == "not evaluated":
        return "Grouped sensitivity not evaluated"
    if status == "retained original documented screening threshold":
        return "Retained under code grouping"
    if status.startswith("site-sensitive"):
        return status.replace("site-sensitive", "Code-group sensitive")
    return status


def paragraph(text: object, style: ParagraphStyle) -> Paragraph:
    return Paragraph(esc(text), style)


def table_style(header_colour: colors.Color = NAVY) -> TableStyle:
    return TableStyle(
        [
            ("BACKGROUND", (0, 0), (-1, 0), header_colour),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("FONTSIZE", (0, 0), (-1, 0), 6.7),
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ("ALIGN", (2, 1), (-1, -1), "CENTER"),
            ("GRID", (0, 0), (-1, -1), 0.35, colors.HexColor("#B9C4CE")),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, LIGHT_GREY]),
            ("LEFTPADDING", (0, 0), (-1, -1), 4),
            ("RIGHTPADDING", (0, 0), (-1, -1), 4),
            ("TOPPADDING", (0, 0), (-1, -1), 4),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ]
    )


def build_report(
    patient_id: str,
    example: dict[str, str],
    continuous_rows: list[dict[str, str]],
    binary_rows: list[dict[str, str]],
    output_path: Path,
) -> None:
    styles = getSampleStyleSheet()
    title = ParagraphStyle(
        "ReportTitle",
        parent=styles["Title"],
        fontName="Helvetica-Bold",
        fontSize=21,
        leading=24,
        textColor=NAVY,
        alignment=TA_LEFT,
        spaceAfter=7,
    )
    subtitle = ParagraphStyle(
        "Subtitle",
        parent=styles["Normal"],
        fontName="Helvetica",
        fontSize=11,
        leading=14,
        textColor=MUTED,
        spaceAfter=10,
    )
    heading = ParagraphStyle(
        "Heading",
        parent=styles["Heading2"],
        fontName="Helvetica-Bold",
        fontSize=15,
        leading=18,
        textColor=NAVY,
        spaceBefore=2,
        spaceAfter=7,
    )
    subheading = ParagraphStyle(
        "Subheading",
        parent=styles["Heading3"],
        fontName="Helvetica-Bold",
        fontSize=10.5,
        leading=12.5,
        textColor=NAVY,
        spaceBefore=5,
        spaceAfter=4,
    )
    body = ParagraphStyle(
        "Body",
        parent=styles["BodyText"],
        fontName="Helvetica",
        fontSize=8.3,
        leading=11.2,
        textColor=colors.HexColor("#243447"),
        spaceAfter=6,
    )
    small = ParagraphStyle(
        "Small",
        parent=body,
        fontSize=6.5,
        leading=8.1,
        spaceAfter=0,
    )
    table_text = ParagraphStyle(
        "TableText",
        parent=small,
        fontSize=6.3,
        leading=7.5,
        alignment=TA_LEFT,
    )
    table_center = ParagraphStyle(
        "TableCenter",
        parent=table_text,
        alignment=TA_CENTER,
    )
    table_header = ParagraphStyle(
        "TableHeader",
        parent=table_center,
        fontName="Helvetica-Bold",
        textColor=colors.white,
    )
    warning = ParagraphStyle(
        "Warning",
        parent=body,
        fontName="Helvetica-Bold",
        fontSize=8.5,
        leading=11,
        textColor=colors.HexColor("#5E4900"),
        spaceAfter=0,
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    document = SimpleDocTemplate(
        str(output_path),
        pagesize=landscape(letter),
        leftMargin=0.42 * inch,
        rightMargin=0.42 * inch,
        topMargin=0.38 * inch,
        bottomMargin=0.38 * inch,
        title="PathoFMPred complete three-representation research-software output",
        author="",
    )

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setStrokeColor(colors.HexColor("#C7D0D9"))
        canvas.setLineWidth(0.4)
        canvas.line(doc.leftMargin, 20, landscape(letter)[0] - doc.rightMargin, 20)
        canvas.setFont("Helvetica", 6.8)
        canvas.setFillColor(MUTED)
        canvas.drawString(doc.leftMargin, 9, f"PathoFMPred research output | {patient_id}")
        canvas.drawRightString(
            landscape(letter)[0] - doc.rightMargin,
            9,
            f"Page {doc.page}",
        )
        canvas.restoreState()

    story = [
        paragraph("PathoFMPred complete three-representation output", title),
        paragraph(
            f"COAD {patient_id} | TITAN, Giga-SSL and Prov-GigaPath | {date.today().isoformat()}",
            subtitle,
        ),
    ]

    warning_table = Table(
        [[paragraph(
            "UNVALIDATED INTERNAL TCGA RESEARCH OUTPUT. BINARY REFERENCE RANK IS NOT PROBABILITY. "
            "DO NOT USE FOR DIAGNOSIS, TREATMENT SELECTION OR CLINICAL RISK ESTIMATION.",
            warning,
        )]],
        colWidths=[10.15 * inch],
    )
    warning_table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), WARNING_BG),
                ("BOX", (0, 0), (-1, -1), 0.9, WARNING_BORDER),
                ("LEFTPADDING", (0, 0), (-1, -1), 9),
                ("RIGHTPADDING", (0, 0), (-1, -1), 9),
                ("TOPPADDING", (0, 0), (-1, -1), 7),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
            ]
        )
    )
    story.extend([warning_table, Spacer(1, 10)])

    summary_data = [[
        paragraph("Representation", table_header),
        paragraph("Continuous outputs", table_header),
        paragraph("Binary outputs", table_header),
        paragraph("Slides pooled", table_header),
        paragraph("Output rule", table_header),
    ]]
    for model in MODEL_ORDER:
        model_continuous = [r for r in continuous_rows if r["foundation_model"] == model]
        model_binary = [r for r in binary_rows if r["foundation_model"] == model]
        slide_counts = sorted({r.get("source_slide_count", "NA") for r in model_continuous + model_binary})
        summary_data.append([
            paragraph(MODEL_LABEL[model], table_text),
            paragraph(len(model_continuous), table_center),
            paragraph(len(model_binary), table_center),
            paragraph(", ".join(slide_counts), table_center),
            paragraph("Q2 >= 0.20; AUROC >= 0.60", table_center),
        ])
    summary = Table(
        summary_data,
        colWidths=[1.3 * inch, 1.25 * inch, 1.15 * inch, 1.0 * inch, 3.0 * inch],
        repeatRows=1,
    )
    summary.setStyle(table_style())
    story.extend([paragraph("Output inventory", heading), summary, Spacer(1, 9)])

    story.append(paragraph("Case context, not used as model input", heading))
    story.append(paragraph(example.get("pathology", "No case context available."), body))
    story.append(paragraph(example.get("source", ""), small))
    story.append(Spacer(1, 5))

    story.append(paragraph("How to read the report", heading))
    reading_points = [
        "PathoFMPred lists only representation-specific fitted objects that crossed the recorded internal performance threshold and passed the package's default sample-size rule.",
        "Continuous predictions remain in the source endpoint units. The internal TCGA rank provides display context and is not a clinical reference interval.",
        "Binary calls use an uncalibrated fitted LDA rule. The original LDA score is model-specific; neither the score nor its TCGA rank is a probability.",
        "The example patients lack reference labels for the displayed outcomes in the processed analysis table, so this report demonstrates software output rather than correctness.",
    ]
    for point in reading_points:
        story.append(paragraph("- " + point, body))

    source_rows = [
        ["Mutations", "TCGA MC3 protein-altering calls within the Bailey tissue-specific driver catalogue"],
        ["Genome doubling and aneuploidy", "Taylor et al. arm-level and genome-doubling variables"],
        ["MSI", "cBioPortal TCGA PanCancer MANTIS and MSIsensor variables"],
        ["Oncogenic pathways", "Sanchez-Vega pathway alteration matrix"],
        ["Immune and genomic context", "Published Thorsson PanImmune computational phenotypes"],
    ]
    source_data = [[paragraph("Feature group", table_header), paragraph("Reference label source", table_header)]]
    source_data += [[paragraph(a, table_text), paragraph(b, table_text)] for a, b in source_rows]
    source_table = Table(source_data, colWidths=[2.2 * inch, 7.95 * inch], repeatRows=1)
    source_table.setStyle(table_style())
    story.extend([Spacer(1, 3), source_table])

    for model_index, model in enumerate(MODEL_ORDER):
        story.append(PageBreak())
        model_continuous = sorted(
            (r for r in continuous_rows if r["foundation_model"] == model),
            key=lambda r: (r.get("family", ""), r.get("endpoint", "")),
        )
        model_binary = sorted(
            (r for r in binary_rows if r["foundation_model"] == model),
            key=lambda r: (r.get("family", ""), r.get("endpoint", "")),
        )
        model_heading = ParagraphStyle(
            f"Heading{model}",
            parent=heading,
            fontSize=17,
            leading=20,
            textColor=MODEL_COLOUR[model],
        )
        story.append(paragraph(
            f"{MODEL_LABEL[model]}: complete predictable output",
            model_heading,
        ))
        story.append(paragraph(
            f"This page reports all {len(model_continuous)} continuous and {len(model_binary)} binary outputs returned for this patient and representation.",
            body,
        ))

        continuous_data = [[
            paragraph("Family", table_header),
            paragraph("Endpoint", table_header),
            paragraph("Prediction", table_header),
            paragraph("Units", table_header),
            paragraph("TCGA rank", table_header),
            paragraph("Q2", table_header),
            paragraph("Spearman", table_header),
            paragraph("n", table_header),
            paragraph("Grouped sensitivity", table_header),
        ]]
        for row in model_continuous:
            continuous_data.append([
                paragraph(family_label(row.get("family", "")), table_text),
                paragraph(row.get("endpoint", ""), table_text),
                paragraph(prediction_value(row.get("prediction")), table_center),
                paragraph(row.get("output_units", ""), table_text),
                paragraph(number(row.get("reference_percentile"), 1), table_center),
                paragraph(number(row.get("primary_screen_q2"), 3), table_center),
                paragraph(number(row.get("primary_screen_spearman"), 3), table_center),
                paragraph(row.get("training_n", "NA"), table_center),
                paragraph(warning_label(row), table_text),
            ])
        continuous_table = Table(
            continuous_data,
            colWidths=[0.78 * inch, 1.58 * inch, 0.72 * inch, 1.15 * inch,
                       0.58 * inch, 0.43 * inch, 0.58 * inch, 0.42 * inch,
                       2.02 * inch],
            repeatRows=1,
        )
        continuous_table.setStyle(table_style(MODEL_COLOUR[model]))
        story.append(KeepTogether([
            paragraph("Continuous internally derived estimates", subheading),
            continuous_table,
        ]))
        story.append(Spacer(1, 7))

        binary_data = [[
            paragraph("Family", table_header),
            paragraph("Endpoint", table_header),
            paragraph("Predicted class", table_header),
            paragraph("LDA score", table_header),
            paragraph("TCGA rank", table_header),
            paragraph("AUROC", table_header),
            paragraph("PR-AUC", table_header),
            paragraph("Training n (+/-)", table_header),
            paragraph("Grouped sensitivity", table_header),
        ]]
        for row in model_binary:
            binary_data.append([
                paragraph(family_label(row.get("family", "")), table_text),
                paragraph(row.get("endpoint", ""), table_text),
                paragraph(binary_call(row), table_center),
                paragraph(number(row.get("lda_score"), 3), table_center),
                paragraph(number(row.get("reference_rank"), 1), table_center),
                paragraph(number(row.get("repeated_auc"), 3), table_center),
                paragraph(number(row.get("repeated_pr_auc"), 3), table_center),
                paragraph(
                    f"{row.get('training_n', 'NA')} ({row.get('training_positive', 'NA')}/{row.get('training_negative', 'NA')})",
                    table_center,
                ),
                paragraph(warning_label(row), table_text),
            ])
        binary_table = Table(
            binary_data,
            colWidths=[0.76 * inch, 1.55 * inch, 0.8 * inch, 0.55 * inch,
                       0.55 * inch, 0.48 * inch, 0.5 * inch, 0.83 * inch,
                       2.15 * inch],
            repeatRows=1,
        )
        binary_table.setStyle(table_style(MODEL_COLOUR[model]))
        for index, row in enumerate(model_binary, start=1):
            fill = POSITIVE_BG if str(row.get("predicted_class", "")) == "1" else NEGATIVE_BG
            binary_table.setStyle(TableStyle([("BACKGROUND", (2, index), (2, index), fill)]))
        story.append(KeepTogether([
            paragraph("Binary research-model calls", subheading),
            binary_table,
        ]))
        story.append(Spacer(1, 5))
        story.append(paragraph(
            "AUROC and PR-AUC are internal repeated out-of-fold performance estimates. "
            "The class call shown here comes from the fitted model object and is not a calibrated probability. "
            "Grouped sensitivity uses TCGA tissue-source-site code, a barcode-derived cohort variable rather than an institution, scanner or laboratory identifier.",
            small,
        ))

    document.build(story, onFirstPage=footer, onLaterPages=footer)


def main() -> None:
    continuous = read_csv(TABLE_DIR / "coad_pathofmpred_multifoundation_predictions.csv")
    binary = read_csv(TABLE_DIR / "coad_pathofmpred_multifoundation_binary_predictions.csv")
    examples = {row["patient_id"]: row for row in read_csv(TABLE_DIR / "coad_package_examples.csv")}
    outputs = {
        "TCGA-AA-A01F": REPORT_DIR / "COAD_example_A_all_models.pdf",
        "TCGA-A6-A56B": REPORT_DIR / "COAD_example_B_all_models.pdf",
    }
    for patient_id, output_path in outputs.items():
        build_report(
            patient_id,
            examples[patient_id],
            [row for row in continuous if row["patient_id"] == patient_id],
            [row for row in binary if row["patient_id"] == patient_id],
            output_path,
        )
        print(output_path)


if __name__ == "__main__":
    main()
