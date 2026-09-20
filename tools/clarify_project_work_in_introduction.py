#!/usr/bin/env python3
"""Clarify the study workflow in the closing Background paragraphs."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from docx import Document


OLD_GAP = (
    "The gap addressed here is a reproducible atlas comparing molecular and derived immune-feature "
    "associations across released pipelines for the same patients and endpoints. The atlas pools slides "
    "before outcome matching, validates at patient level and preserves negative and ineligible results. "
    "As a secondary output, we developed PathoFMPred [22], an R package for representation-specific "
    "feature validation and permitted fitted linear models. The main contribution remains the "
    "three-pipeline patient-level benchmark of outcome provenance, partition stability and "
    "cohort-structure sensitivity."
)

OLD_MODELS = (
    "TITAN is a multimodal whole-slide model trained with visual self-supervision and vision-language "
    "alignment; its published Mass-340K pretraining corpus excluded TCGA, although TCGA was used for "
    "downstream evaluation [17]. Giga-SSL is a gigapixel self-supervised whole-slide representation whose "
    "official repository distributes 512-dimensional TCGA embeddings [18,19]; TCGA was used during "
    "Giga-SSL development, and direct overlap between its representation-learning images and the evaluated "
    "slides cannot be excluded. Prov-GigaPath combines a tile encoder with a long-context slide encoder "
    "trained on Providence health-system pathology data; we used the final 768-dimensional slide layer from "
    "the public TCGA embedding dataset [20,21]. No weights were fine-tuned and no downstream molecular labels "
    "entered representation learning in this study. Giga-SSL is therefore label-held-out in the downstream "
    "cross-validation, but not necessarily image-unseen at the representation-learning stage."
)

OLD_QUESTION = (
    "The primary question was cancer-specific: which directly observed alterations and which separately "
    "labelled sequencing-derived, transcriptomic, inferred immune, composite genomic-context and same-H&E "
    "reference phenotypes show held-out association with a released representation, and how stable is that "
    "association across TITAN, Giga-SSL and Prov-GigaPath? Here 'predictability' means cross-validated "
    "agreement with the supplied reference label. It does not imply causality, mechanism, analytical recovery "
    "of the originating assay or assay replacement. Molecular subtype was not analysed."
)

NEW_WORKFLOW = (
    "In this retrospective project, we harmonised the released slide-level embeddings for TITAN, Giga-SSL "
    "and Prov-GigaPath across 32 TCGA cancers and identified 8,241 patients shared by all three resources. "
    "Within each representation, we averaged all eligible diagnostic slides from a patient before joining "
    "molecular outcomes. We then evaluated 1,933 shared cancer-endpoint pairs with the same nested "
    "patient-level PLS1 or PLS-LDA pipeline, using identical patients, folds, seeds and tuning rules. Outcomes "
    "were analysed within cancer and separated into directly observed genomic alterations, sequencing-derived "
    "burdens, transcriptomic signatures, inferred immune-cell fractions, composite genomic-context scores and "
    "same-H&E quantities. We compared cross-validated performance across the three representations, repeated "
    "selected and near-threshold pairs across alternative partitions, and repeated all union-positive pairs "
    "with complete TCGA tissue-source-site codes held apart."
)

NEW_SUPPORTING = (
    "We also performed a deeper, supporting TITAN-only screen in 9,404 patients, with permutation testing, "
    "multiplicity correction, repeated validation and tissue-source-site-code sensitivity. Negative and "
    "sample-size-ineligible results were retained in the atlas. As a secondary output, we created PathoFMPred "
    "[22], an R package for representation-specific feature validation and permitted fitted linear models. "
    "The main contribution is therefore the matched three-pipeline patient-level benchmark; the TITAN screen "
    "and software are supporting resource layers. Here 'predictability' means cross-validated agreement with "
    "the supplied reference label. It does not imply causality, mechanism, analytical recovery of the "
    "originating assay or assay replacement. Molecular subtype was not analysed."
)


def find_paragraph(document: Document, old: str):
    matches = [paragraph for paragraph in document.paragraphs if paragraph.text == old]
    if len(matches) != 1:
        raise ValueError(f"Expected one exact paragraph match, found {len(matches)}")
    paragraph = matches[0]
    if len(paragraph.runs) != 1:
        raise ValueError("Target paragraph unexpectedly contains multiple runs")
    return paragraph


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--backup", type=Path, required=True)
    args = parser.parse_args()

    shutil.copy2(args.input, args.backup)
    document = Document(args.input)

    gap_paragraph = find_paragraph(document, OLD_GAP)
    model_paragraph = find_paragraph(document, OLD_MODELS)
    question_paragraph = find_paragraph(document, OLD_QUESTION)

    gap_paragraph.runs[0].text = OLD_MODELS
    model_paragraph.runs[0].text = NEW_WORKFLOW
    question_paragraph.runs[0].text = NEW_SUPPORTING

    document.save(args.output)


if __name__ == "__main__":
    main()
