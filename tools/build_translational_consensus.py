#!/usr/bin/env python3
"""Build a target-level cross-representation and TSS-sensitivity audit."""
from __future__ import annotations

import csv
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TABLES = ROOT / "results" / "tables"
OUT = ROOT / "data" / "reference"
MODELS = ("TITAN", "GigaSSL", "ProvGigaPath")


def read(name):
    with (TABLES / name).open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def truth(value):
    return str(value).upper() == "TRUE"


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


targets = read("foundation_model_target_comparison.csv")
pairwise = read("foundation_model_pairwise_summary.csv")
site_rows = read("continuous_site_grouped_sensitivity.csv") + read("binary_site_grouped_sensitivity.csv")
site = {(r["outcome_type"] if "outcome_type" in r else ("binary" if "positive" in r else "continuous"),
         r["family"], r["tumor_type"], r["endpoint"]): r for r in site_rows}
matched_grouped_rows = read("foundation_model_tss_grouped_sensitivity.csv")
matched_grouped = {
    (r["outcome_type"], r["family"], r["subfamily"], r["tumor_type"],
     r["endpoint"], r["source"], r["foundation_model"]): r
    for r in matched_grouped_rows
}
robustness_rows = read("foundation_model_internal_robustness_classification.csv")
robustness = {
    (r["outcome_type"], r["family"], r["subfamily"], r["tumor_type"],
     r["endpoint"], r["source"]): r for r in robustness_rows
}

records = []
for row in targets:
    effects = {m: number(row[f"effect_{m}"]) for m in MODELS}
    supported = [m for m in MODELS if truth(row[f"screening_positive_{m}"])]
    n_supported = len(supported)
    if n_supported == 3:
        consensus = "retained by all three"
        priority_score = min(effects.values())
    elif n_supported == 2:
        consensus = "retained by two"
        priority_score = sorted((effects[m] for m in supported), reverse=True)[1]
    elif n_supported == 1:
        consensus = f"unique to {supported[0]}"
        priority_score = effects[supported[0]]
    else:
        consensus = "no effect-threshold crossing"
        priority_score = max(effects.values())

    sr = site.get((row["outcome_type"], row["family"], row["tumor_type"], row["endpoint"]))
    if sr:
        grouped = number(sr.get("site_grouped_q2", sr.get("site_grouped_balanced_accuracy")))
        random = number(sr.get("random_q2", sr.get("random_balanced_accuracy")))
        threshold = 0.20 if row["outcome_type"] == "continuous" else 0.60
        retained = grouped is not None and grouped >= threshold
        tss_status = "retained under TSS grouping" if retained else "fell below threshold under TSS grouping"
        near_chance = grouped is not None and grouped <= (0 if row["outcome_type"] == "continuous" else 0.50)
    else:
        grouped = random = None
        retained = near_chance = False
        tss_status = "not evaluated in TITAN candidate TSS analysis"

    task_key = (row["outcome_type"], row["family"], row["subfamily"],
                row["tumor_type"], row["endpoint"], row["source"])
    grouped_by_model = {
        model: matched_grouped.get(task_key + (model,)) for model in MODELS
    }
    grouped_metrics = {
        model: (number(grouped_by_model[model][
            "grouped_q2" if row["outcome_type"] == "continuous"
            else "grouped_balanced_accuracy"
        ]) if grouped_by_model[model] else None) for model in MODELS
    }
    grouped_retained = {
        model: (truth(grouped_by_model[model]["retained_primary_crossing"])
                if grouped_by_model[model] else False)
        for model in MODELS
    }
    maturity = robustness.get(task_key, {
        "sample_size_maturity": "FALSE",
        "tss_retention_class": "not evaluated: no primary crossing",
        "internal_robustness_class": "not prioritised: no primary crossing",
    })

    records.append({
        "outcome_type": row["outcome_type"], "family": row["family"],
        "tumor_type": row["tumor_type"], "endpoint": row["endpoint"],
        "n": row["n"], "positive": row["positive"], "negative": row["negative"],
        "representations_retained": "+".join(supported) if supported else "None",
        "n_representations_retained": n_supported, "consensus_class": consensus,
        "effect_TITAN": effects["TITAN"], "effect_GigaSSL": effects["GigaSSL"],
        "effect_ProvGigaPath": effects["ProvGigaPath"], "priority_score": priority_score,
        "TITAN_tss_random_metric": random, "TITAN_tss_grouped_metric": grouped,
        "TITAN_tss_status": tss_status, "TITAN_tss_near_chance_or_worse": near_chance,
        "matched_grouped_metric_TITAN": grouped_metrics["TITAN"],
        "matched_grouped_metric_GigaSSL": grouped_metrics["GigaSSL"],
        "matched_grouped_metric_ProvGigaPath": grouped_metrics["ProvGigaPath"],
        "matched_grouped_retained_TITAN": grouped_retained["TITAN"],
        "matched_grouped_retained_GigaSSL": grouped_retained["GigaSSL"],
        "matched_grouped_retained_ProvGigaPath": grouped_retained["ProvGigaPath"],
        "sample_size_maturity": truth(maturity["sample_size_maturity"]),
        "matched_tss_retention_class": maturity["tss_retention_class"],
        "internal_robustness_class": maturity["internal_robustness_class"],
        "interpretation": (
            maturity["internal_robustness_class"]
            + "; internal TCGA prioritisation only; external validation required"
        ),
    })

fields = list(records[0])
with (OUT / "translational_consensus_target_audit.csv").open("w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=fields)
    writer.writeheader(); writer.writerows(records)

summary = defaultdict(Counter)
for r in records:
    summary[(r["outcome_type"], r["family"])][r["consensus_class"]] += 1
summary_rows = []
for (outcome, family), counts in sorted(summary.items()):
    summary_rows.append({"outcome_type": outcome, "family": family,
                         "retained_all_three": counts["retained by all three"],
                         "retained_two": counts["retained by two"],
                         "unique_TITAN": counts["unique to TITAN"],
                         "unique_GigaSSL": counts["unique to GigaSSL"],
                         "unique_ProvGigaPath": counts["unique to ProvGigaPath"],
                         "no_crossing": counts["no effect-threshold crossing"]})
with (OUT / "translational_consensus_by_endpoint_family.csv").open("w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=list(summary_rows[0]))
    writer.writeheader(); writer.writerows(summary_rows)

# A dedicated paired summary for the two released embedding pipelines whose
# reported pretraining corpora excluded TCGA. This is derived from the existing
# matched results and does not refit any model.
pairwise_titan_prov = {
    r["outcome_type"]: r for r in pairwise
    if r["comparison"] == "ProvGigaPath versus TITAN"
}
titan_prov_rows = []
for outcome_type in ("continuous", "binary"):
    subset = [r for r in targets if r["outcome_type"] == outcome_type]
    both = sum(truth(r["screening_positive_TITAN"]) and truth(r["screening_positive_ProvGigaPath"]) for r in subset)
    titan_only = sum(truth(r["screening_positive_TITAN"]) and not truth(r["screening_positive_ProvGigaPath"]) for r in subset)
    prov_only = sum(not truth(r["screening_positive_TITAN"]) and truth(r["screening_positive_ProvGigaPath"]) for r in subset)
    neither = len(subset) - both - titan_only - prov_only
    paired = pairwise_titan_prov[outcome_type]
    titan_prov_rows.append({
        "outcome_type": outcome_type,
        "targets": len(subset),
        "both_effect_threshold_crossing": both,
        "TITAN_only_crossing": titan_only,
        "ProvGigaPath_only_crossing": prov_only,
        "neither_crossing": neither,
        "TITAN_higher_effect": paired["TITAN_higher"],
        "ProvGigaPath_higher_effect": paired["other_higher"],
        "tied_effect": paired["tied"],
        "median_delta_ProvGigaPath_minus_TITAN": paired["median_delta_vs_TITAN"],
        "cluster_bootstrap_low": paired["cluster_bootstrap_low"],
        "cluster_bootstrap_high": paired["cluster_bootstrap_high"],
        "spearman_effect": paired["spearman_effect"],
        "uncertainty_method": paired["uncertainty_method"],
        "scope_note": (
            "paired released embedding-pipeline comparison under the specified PLS1/PLS-LDA probe; "
            "reported pretraining corpora excluded TCGA; not external validation or isolated model quality"
        ),
    })
with (OUT / "titan_provgigapath_paired_summary.csv").open("w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=list(titan_prov_rows[0]))
    writer.writeheader(); writer.writerows(titan_prov_rows)

# A compact, deterministic set for the main table: strongest consensus, shared,
# unique and grouped-collapse examples. Duplicate records are removed.
selected = []
def take(rows, n, label):
    for r in sorted(rows, key=lambda x: x["priority_score"], reverse=True):
        key = (r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"])
        if key not in {(x["outcome_type"], x["family"], x["tumor_type"], x["endpoint"]) for x in selected}:
            x = dict(r); x["selection_reason"] = label; selected.append(x)
            if sum(y["selection_reason"] == label for y in selected) == n:
                break
def take_all_three(outcome_type):
    pool = [r for r in records if r["n_representations_retained"] == 3 and r["outcome_type"] == outcome_type]
    first = max(pool, key=lambda r: (r["effect_TITAN"], r["tumor_type"], r["endpoint"]))
    x = dict(first)
    x["selection_reason"] = f"all-three {outcome_type}: largest TITAN effect"
    selected.append(x)
    remaining = [r for r in pool if (r["family"], r["tumor_type"], r["endpoint"]) != (first["family"], first["tumor_type"], first["endpoint"])]
    second = max(remaining, key=lambda r: ((r["effect_GigaSSL"] + r["effect_ProvGigaPath"]) / 2, r["tumor_type"], r["endpoint"]))
    x = dict(second)
    x["selection_reason"] = f"all-three {outcome_type}: largest mean alternative-representation effect"
    selected.append(x)

# Replace the generic duplicated all-three labels with two explicit,
# deterministic selection rules per outcome type.
take_all_three("continuous")
take_all_three("binary")
take([r for r in records if r["n_representations_retained"] == 2], 2, "strongest retained by two")
take([r for r in records if r["n_representations_retained"] == 1], 2, "strongest representation-specific")
collapse = [r for r in records if r["TITAN_tss_status"].startswith("fell")]
collapse_added = 0
for r in sorted(collapse, key=lambda x: (x["TITAN_tss_grouped_metric"] or -999) - (x["TITAN_tss_random_metric"] or -999)):
    key = (r["outcome_type"], r["family"], r["tumor_type"], r["endpoint"])
    if key not in {(x["outcome_type"], x["family"], x["tumor_type"], x["endpoint"]) for x in selected}:
        x = dict(r); x["selection_reason"] = "largest tissue-source-site-code-grouped collapse"; selected.append(x)
        collapse_added += 1
        if collapse_added == 2:
            break
with (OUT / "translational_consensus_main_examples.csv").open("w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=list(selected[0]))
    writer.writeheader(); writer.writerows(selected)

print(
    f"wrote {len(records)} target rows, {len(summary_rows)} family rows, "
    f"{len(selected)} main examples and {len(titan_prov_rows)} TITAN–Prov-GigaPath summary rows"
)
