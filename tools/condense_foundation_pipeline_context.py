#!/usr/bin/env python3
"""Condense foundation-pipeline context without removing key distinctions."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from docx import Document


OLD = (
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

NEW = (
    "TITAN is a multimodal whole-slide model trained by visual self-supervision and vision-language "
    "alignment; its published pretraining corpus excluded TCGA [17]. Giga-SSL is a self-supervised gigapixel "
    "representation with released 512-dimensional TCGA embeddings [18,19]; TCGA was used during development, "
    "so direct image overlap cannot be excluded. Prov-GigaPath combines tile and long-context slide encoders "
    "trained on Providence pathology data; we used its public 768-dimensional TCGA slide embeddings [20,21]. "
    "We did not fine-tune any representation or use molecular labels during downstream feature extraction. "
    "Giga-SSL is label-held-out in cross-validation but not necessarily image-unseen during representation "
    "learning."
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--backup", type=Path, required=True)
    args = parser.parse_args()

    shutil.copy2(args.input, args.backup)
    document = Document(args.input)
    matches = [paragraph for paragraph in document.paragraphs if paragraph.text == OLD]
    if len(matches) != 1 or len(matches[0].runs) != 1:
        raise ValueError(f"Expected one single-run paragraph match, found {len(matches)}")
    matches[0].runs[0].text = NEW
    document.save(args.output)


if __name__ == "__main__":
    main()
