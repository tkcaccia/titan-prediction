#!/usr/bin/env python3
"""Condense the explicit project summary while preserving its content."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from docx import Document


OLD_WORKFLOW = (
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

OLD_SUPPORTING = (
    "We also performed a deeper, supporting TITAN-only screen in 9,404 patients, with permutation testing, "
    "multiplicity correction, repeated validation and tissue-source-site-code sensitivity. Negative and "
    "sample-size-ineligible results were retained in the atlas. As a secondary output, we created PathoFMPred "
    "[22], an R package for representation-specific feature validation and permitted fitted linear models. "
    "The main contribution is therefore the matched three-pipeline patient-level benchmark; the TITAN screen "
    "and software are supporting resource layers. Here 'predictability' means cross-validated agreement with "
    "the supplied reference label. It does not imply causality, mechanism, analytical recovery of the "
    "originating assay or assay replacement. Molecular subtype was not analysed."
)

NEW_WORKFLOW = (
    "In this retrospective study, we harmonised TITAN, Giga-SSL and Prov-GigaPath slide embeddings across 32 "
    "TCGA cancers and identified 8,241 shared patients. Eligible diagnostic slides were averaged within patient "
    "before outcomes were joined. Using identical patients, folds, seeds and tuning rules, we evaluated 1,933 "
    "cancer-specific prediction tasks with nested patient-level PLS regression or PLS-LDA. Outcomes covered direct genomic "
    "alterations, sequencing-derived burdens, transcriptomic signatures, inferred immune-cell fractions, "
    "composite genomic-context scores and same-H&E quantities. We compared representation performance and "
    "tested stability across alternative partitions and folds holding complete TCGA tissue-source-site codes "
    "apart."
)

NEW_SUPPORTING = (
    "A supporting 9,404-patient TITAN screen added permutation testing, multiplicity correction and repeated "
    "validation, while retaining negative and sample-size-ineligible results. As a secondary output, we created "
    "PathoFMPred [22], an R package for representation-specific input validation and permitted fitted linear "
    "models. The primary contribution is the matched three-pipeline benchmark; the TITAN screen and software "
    "are supporting layers. Here 'predictability' means cross-validated agreement with the supplied reference "
    "label, not causality, assay recovery or assay replacement. Molecular subtype was not analysed."
)


def replace(document: Document, old: str, new: str) -> None:
    matches = [paragraph for paragraph in document.paragraphs if paragraph.text == old]
    if len(matches) != 1 or len(matches[0].runs) != 1:
        raise ValueError(f"Expected one single-run paragraph match, found {len(matches)}")
    matches[0].runs[0].text = new


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--backup", type=Path, required=True)
    args = parser.parse_args()

    shutil.copy2(args.input, args.backup)
    document = Document(args.input)
    replace(document, OLD_WORKFLOW, NEW_WORKFLOW)
    replace(document, OLD_SUPPORTING, NEW_SUPPORTING)
    document.save(args.output)


if __name__ == "__main__":
    main()
