#!/usr/bin/env python3
"""Attach continuous reliability evidence fields to TITAN registries."""
from __future__ import annotations
import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUDIT = ROOT / "results" / "tables" / "continuous_reliability_by_model.csv"
LIMITED_REASON = (
    "fewer than 100 TCGA patients; internally validated only; inspect repeated "
    "Q2, prediction stability and component-selection metadata"
)

with AUDIT.open(newline="", encoding="utf-8-sig") as handle:
    audit_rows = list(csv.DictReader(handle))
audit = {(r["family"], r["tumor_type"], r["endpoint"]): r for r in audit_rows}

new_fields = [
    "continuous_evidence_category", "continuous_repeat_q2_sd",
    "continuous_prediction_repeat_spearman", "continuous_selected_components_median",
    "continuous_selected_components_min", "continuous_selected_components_max",
    "continuous_outer_fits_at_ceiling", "continuous_outer_fits",
    "continuous_outer_fit_ceiling_fraction", "continuous_any_outer_fit_at_ceiling",
]

for path in [ROOT / "models" / "model_registry.csv",
             ROOT.parent / "TITANPred" / "inst" / "extdata" / "model_registry.csv"]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle)); fields = list(rows[0])
    for field in new_fields:
        if field not in fields: fields.append(field)
    for row in rows:
        if row.get("foundation_model", "TITAN") != "TITAN" or row.get("outcome_type") != "continuous":
            continue
        a = audit.get((row["family"], row["cancer_type"], row["endpoint"]))
        if not a: continue
        limited = int(float(a["n"])) < 100
        row["continuous_evidence_category"] = (
            "limited continuous evidence (<100 patients)" if limited
            else "standard continuous internal evidence (>=100 patients)"
        )
        row["continuous_repeat_q2_sd"] = a["repeated_q2_sd"]
        row["continuous_prediction_repeat_spearman"] = a["prediction_repeat_spearman_mean"]
        row["continuous_selected_components_median"] = a["selected_components_median"]
        row["continuous_selected_components_min"] = a["selected_components_min"]
        row["continuous_selected_components_max"] = a["selected_components_max"]
        row["continuous_outer_fits_at_ceiling"] = a["outer_fits_at_ceiling"]
        row["continuous_outer_fits"] = a["outer_fits"]
        row["continuous_outer_fit_ceiling_fraction"] = a["outer_fit_ceiling_fraction"]
        row["continuous_any_outer_fit_at_ceiling"] = a["any_outer_fit_at_ceiling"]
        if limited:
            row["model_evidence_tier"] = "exploratory_limited_continuous_evidence"
            row["default_inference"] = "FALSE"
            row["limited_evidence_reason"] = LIMITED_REASON
        elif not row.get("model_evidence_tier"):
            row["model_evidence_tier"] = "standard_continuous_internal_evidence"
            row["default_inference"] = "TRUE"
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=fields, extrasaction="ignore", lineterminator="\n"
        )
        writer.writeheader(); writer.writerows(rows)
    print(path)
