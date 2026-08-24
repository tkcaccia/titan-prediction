#!/usr/bin/env python3
"""Convert published Giga-SSL and Prov-GigaPath TCGA embeddings to CSV.gz.

The conversion is deterministic and outcome-blind. Prov-GigaPath records all
14 slide-encoder states; the prespecified representation is the final state
(index 13), corresponding to ``last_layer_embed`` in the upstream pipeline.
"""
from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def write_rows(path: Path, ids, matrix, prefix: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(path, "wt", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["filename"] + [f"{prefix}_{i:03d}" for i in range(matrix.shape[1])])
        for identifier, values in zip(ids, matrix):
            writer.writerow([identifier] + [format(float(x), ".9g") for x in values])


def convert_gigassl(source: Path, output: Path) -> dict:
    ids_path = source / "ids.npy"
    embeddings_path = source / "embeddings.npy"
    ids = np.load(ids_path, allow_pickle=False)
    embeddings = np.load(embeddings_path, allow_pickle=False)
    if embeddings.ndim != 2 or embeddings.shape[1] != 512 or len(ids) != len(embeddings):
        raise ValueError(f"Unexpected Giga-SSL schema: ids={ids.shape}, embeddings={embeddings.shape}")
    write_rows(output, ids, embeddings, "gigassl")
    return {
        "foundation_model": "Giga-SSL", "slides": len(ids), "dimensions": 512,
        "source_files": [str(ids_path), str(embeddings_path)],
        "source_sha256": [sha256(ids_path), sha256(embeddings_path)],
        "representation": "published TCGA_encoded_t5e1000 slide embedding",
    }


def convert_provgigapath(source: Path, output: Path, layer: int) -> dict:
    try:
        import pyarrow.parquet as pq
    except ImportError as exc:
        raise SystemExit("PyArrow is required for Prov-GigaPath conversion.") from exc
    parquet = pq.ParquetFile(source)
    ids, blocks = [], []
    for batch in parquet.iter_batches(columns=["filename", "embedding"], batch_size=256):
        identifiers = batch.column(0).to_pylist()
        embeddings = batch.column(1).to_pylist()
        block = np.asarray([x[layer] for x in embeddings], dtype=np.float32)
        if block.ndim != 2 or block.shape[1] != 768:
            raise ValueError(f"Unexpected Prov-GigaPath layer schema: {block.shape}")
        ids.extend(identifiers)
        blocks.append(block)
    matrix = np.vstack(blocks)
    ids = [x[:-3] if x.endswith(".h5") else x for x in ids]
    # The published Parquet contains repeated rows for 1,402 slide IDs. The
    # repeated final-layer vectors are byte-for-byte numerically identical.
    # Retain the first occurrence so a physical slide is never overweighted.
    first = {}
    keep = []
    for i, identifier in enumerate(ids):
        if identifier not in first:
            first[identifier] = i
            keep.append(i)
        elif not np.array_equal(matrix[first[identifier]], matrix[i]):
            raise ValueError(f"Conflicting duplicate Prov-GigaPath slide: {identifier}")
    duplicate_rows_removed = len(ids) - len(keep)
    ids = [ids[i] for i in keep]
    matrix = matrix[keep]
    write_rows(output, ids, matrix, "provgigapath")
    return {
        "foundation_model": "Prov-GigaPath", "slides": len(ids), "dimensions": 768,
        "source_files": [str(source)], "source_sha256": [sha256(source)],
        "representation": f"published slide-encoder state index {layer} (final layer)",
        "layer_index": layer,
        "duplicate_rows_removed": duplicate_rows_removed,
        "duplicate_rule": "retain first occurrence only after exact final-layer equality check",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, choices=("gigassl", "provgigapath"))
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--provgigapath-layer", type=int, default=13)
    args = parser.parse_args()
    if args.model == "gigassl":
        manifest = convert_gigassl(args.source, args.output)
    else:
        manifest = convert_provgigapath(args.source, args.output, args.provgigapath_layer)
    manifest["converted_file"] = str(args.output)
    manifest["converted_sha256"] = sha256(args.output)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
