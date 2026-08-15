suppressPackageStartupMessages(library(data.table))
claims <- fread("data/reference/prior_mutation_claims.csv")
current <- fread("results/tables/binary_screen.csv")[family == "driver_mutation"]

claims[, current_cancer := prior_cancer]
claims[prior_cancer == "SKCM01", current_cancer := "SKCM"]
claims[prior_cancer %in% c("CRC", "SKCM06"), current_cancer := NA_character_]

out <- merge(
  claims,
  current[, .(
    current_cancer = tumor_type, gene = endpoint, n, positive, negative,
    current_balanced_accuracy = balanced_accuracy,
    current_adjusted_balanced_accuracy = adjusted_balanced_accuracy,
    current_q = q_value, current_tier = tier
  )],
  by = c("current_cancer", "gene"), all.x = TRUE
)
out[, current_status := fifelse(
  prior_cancer == "CRC", "pooled_colorectal_cohort_not_directly_comparable",
  fifelse(prior_cancer == "SKCM06", "metastatic_sample_type_excluded",
  fifelse(is.na(current_balanced_accuracy), "not_eligible_or_not_tested",
  fifelse(current_tier %in% c("A", "B"),
          paste0("recovered_tier_", current_tier), "tested_not_supported"))))]
setcolorder(out, c(
  "study", "prior_cancer", "gene", "prior_metric", "prior_evidence",
  "prior_note", "source_url", "current_cancer", "current_status", "n",
  "positive", "negative", "current_balanced_accuracy",
  "current_adjusted_balanced_accuracy", "current_q", "current_tier"
))
setorder(out, study, prior_cancer, gene)
fwrite(out, "results/tables/prior_mutation_literature_crosswalk.csv")

# One row per comparable cancer-gene pair for discussion-level counts. Multiple
# prior studies of the same pair are retained in the semicolon-delimited field.
comparable <- out[!is.na(current_cancer)]
pair_summary <- comparable[, .(
  studies = paste(sort(unique(study)), collapse = ";"),
  prior_reports = .N,
  current_status = first(current_status),
  n = first(n), positive = first(positive), negative = first(negative),
  current_balanced_accuracy = first(current_balanced_accuracy),
  current_adjusted_balanced_accuracy = first(current_adjusted_balanced_accuracy),
  current_q = first(current_q), current_tier = first(current_tier)
), by = .(current_cancer, gene)]
setorder(pair_summary, current_status, current_cancer, gene)
fwrite(pair_summary, "results/tables/prior_mutation_literature_pair_summary.csv")

status_summary <- unique(out[, .(study, prior_cancer, gene, current_status)])[, .N,
  by = current_status][order(current_status)]
fwrite(status_summary, "results/tables/prior_mutation_literature_status_summary.csv")
print(status_summary)
