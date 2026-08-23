#!/usr/bin/env python3
"""Download and convert the official TCGA TITAN slide embeddings to CSV.

The pickle must come from the gated MahmoodLab/TITAN model repository. Python
pickle files can execute code while loading; never use this script on an
untrusted pickle. Raw embeddings remain subject to the upstream terms and are
not committed to this repository.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import pickle
import ssl
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

import numpy as np

try:
    import certifi
except ImportError:  # pragma: no cover - system CA bundle is usually sufficient
    certifi = None


MODEL_REPOSITORY = "https://huggingface.co/MahmoodLab/TITAN"
OFFICIAL_FILENAME = "TCGA_TITAN_features.pkl"
OFFICIAL_URL = (
    f"{MODEL_REPOSITORY}/resolve/main/{OFFICIAL_FILENAME}?download=true"
)
EXPECTED_DIMENSIONS = 768


def ssl_context() -> ssl.SSLContext:
    return ssl.create_default_context(cafile=certifi.where() if certifi else None)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download_official(destination: Path, token: str | None) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(OFFICIAL_URL)
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, context=ssl_context()) as response, \
                destination.open("wb") as out:
            while block := response.read(1024 * 1024):
                out.write(block)
    except urllib.error.HTTPError as exc:
        destination.unlink(missing_ok=True)
        if exc.code in (401, 403):
            raise SystemExit(
                "TITAN access is gated. Accept the MahmoodLab/TITAN terms, "
                "create a read token, and export it as HF_TOKEN."
            ) from exc
        raise


def as_vector(value: object) -> np.ndarray:
    if isinstance(value, dict):
        for key in ("embedding", "embeddings", "feature", "features"):
            if key in value:
                value = value[key]
                break
    vector = np.asarray(value)
    vector = np.squeeze(vector)
    if vector.ndim != 1 or vector.size != EXPECTED_DIMENSIONS:
        raise ValueError(
            f"Expected one {EXPECTED_DIMENSIONS}-element embedding; got {vector.shape}"
        )
    if not np.issubdtype(vector.dtype, np.number):
        raise ValueError(f"Embedding has non-numeric dtype {vector.dtype}")
    if not np.isfinite(vector).all():
        raise ValueError("Embedding contains non-finite values")
    return vector.astype(np.float64, copy=False)


def extract_rows(obj: object) -> Iterable[tuple[str, np.ndarray]]:
    if isinstance(obj, dict):
        filename_key = next(
            (key for key in ("filename", "filenames", "slide_id", "slide_ids") if key in obj),
            None,
        )
        feature_key = next(
            (key for key in ("feature", "features", "embedding", "embeddings") if key in obj),
            None,
        )
        if filename_key and feature_key:
            filenames = list(obj[filename_key])
            features = np.asarray(obj[feature_key])
            if len(filenames) != len(features):
                raise ValueError("Filename and embedding arrays have different lengths")
            for filename, vector in zip(filenames, features):
                yield str(filename), as_vector(vector)
            return
        for filename, vector in obj.items():
            yield str(filename), as_vector(vector)
        return

    if isinstance(obj, (list, tuple)):
        for item in obj:
            if not isinstance(item, (list, tuple)) or len(item) != 2:
                raise ValueError("List input must contain (filename, embedding) pairs")
            yield str(item[0]), as_vector(item[1])
        return

    raise ValueError(
        f"Unsupported pickle root type {type(obj).__name__}; expected a mapping "
        "or a sequence of (filename, embedding) pairs"
    )


def convert(source: Path, destination: Path, sort_filenames: bool) -> int:
    with source.open("rb") as handle:
        obj = pickle.load(handle)  # nosec: input must be the trusted official artifact
    rows = list(extract_rows(obj))
    if sort_filenames:
        rows.sort(key=lambda item: item[0])
    filenames = [row[0] for row in rows]
    if len(set(filenames)) != len(filenames):
        raise ValueError("Duplicate slide identifiers were found in the pickle")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".partial")
    with temporary.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["filename", *[f"titan_{i:03d}" for i in range(768)]])
        for filename, vector in rows:
            writer.writerow([filename, *vector.tolist()])
    temporary.replace(destination)
    return len(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=Path(OFFICIAL_FILENAME))
    parser.add_argument("--output", type=Path, default=Path("TCGA_TITAN_features.csv"))
    parser.add_argument(
        "--download", action="store_true",
        help="Download the gated official pickle before conversion if it is absent.",
    )
    parser.add_argument(
        "--token-env", default="HF_TOKEN",
        help="Environment variable containing a Hugging Face read token.",
    )
    parser.add_argument("--sort-filenames", action="store_true")
    parser.add_argument(
        "--acknowledge-trusted-pickle", action="store_true",
        help="Required acknowledgement that the pickle is the trusted official artifact.",
    )
    args = parser.parse_args()
    if not args.acknowledge_trusted_pickle:
        parser.error("--acknowledge-trusted-pickle is required because pickle is executable")
    if not args.input.exists():
        if not args.download:
            parser.error(f"Input does not exist: {args.input}")
        download_official(args.input, os.getenv(args.token_env))

    source_hash = sha256(args.input)
    rows = convert(args.input, args.output, args.sort_filenames)
    output_hash = sha256(args.output)
    provenance = {
        "official_repository": MODEL_REPOSITORY,
        "official_download_url": OFFICIAL_URL,
        "official_filename": OFFICIAL_FILENAME,
        "source_file": str(args.input.resolve()),
        "source_sha256": source_hash,
        "output_file": str(args.output.resolve()),
        "output_sha256": output_hash,
        "rows": rows,
        "feature_columns": EXPECTED_DIMENSIONS,
        "filename_order": "sorted" if args.sort_filenames else "pickle insertion order",
        "converted_utc": datetime.now(timezone.utc).isoformat(),
    }
    provenance_path = args.output.with_suffix(args.output.suffix + ".provenance.json")
    provenance_path.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(provenance, indent=2))


if __name__ == "__main__":
    main()
