#!/usr/bin/env python3
"""Extract only pathway-member genes from the large UCSC Xena matrix."""

import argparse
import csv
import gzip
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expression", required=True)
    parser.add_argument("--gene-sets", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    wanted = set()
    with open(args.gene_sets, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            # The UCSC Xena Pan-Cancer matrix uses HGNC symbols in its first
            # column, despite some all-numeric symbols appearing at the top.
            gene = row.get("gene_symbol", "").strip()
            if gene:
                wanted.add(gene)
    if not wanted:
        raise RuntimeError("No gene_symbol identifiers were found in the gene-set file")

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    retained = 0
    with gzip.open(args.expression, "rt", encoding="utf-8", newline="") as source:
        with gzip.open(output, "wt", encoding="utf-8", newline="") as target:
            header = source.readline()
            if not header.startswith("sample\t"):
                raise RuntimeError("Unexpected UCSC Xena expression header")
            target.write(header)
            for line in source:
                gene = line.split("\t", 1)[0]
                if gene in wanted:
                    target.write(line)
                    retained += 1

    if retained == 0:
        raise RuntimeError("No pathway-member genes matched the expression matrix")
    print(f"Retained {retained} expression rows for {len(wanted)} requested genes")


if __name__ == "__main__":
    main()
