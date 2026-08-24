suppressPackageStartupMessages(library(data.table))
claims <- fread("data/reference/prior_mutation_claims.csv")
current <- fread("results/tables/binary_screen.csv")[family == "driver_mutation"]

claims[, current_cancer := prior_cancer]
claims[prior_cancer == "SKCM01", current_cancer := "SKCM"]
# Earlier colorectal studies commonly pooled colon and rectal cancers. Map
# those claims to both current cancer-specific strata while retaining the
# broader-cohort scope explicitly; an exact-code join would misclassify known
# CRC results as absent. Metastatic melanoma remains outside the primary-tumour
# analysis population.
crc_claims <- copy(claims[prior_cancer == "CRC"])
claims <- claims[prior_cancer != "CRC"]
if (nrow(crc_claims)) {
  claims <- rbindlist(list(
    claims,
    copy(crc_claims)[, current_cancer := "COAD"],
    copy(crc_claims)[, current_cancer := "READ"]
  ), use.names = TRUE)
}
claims[prior_cancer == "SKCM06", current_cancer := NA_character_]

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
  prior_cancer == "SKCM06", "metastatic_sample_type_excluded",
  fifelse(is.na(current_balanced_accuracy), "not_eligible_or_not_tested",
  fifelse(current_tier %in% c("A", "B"),
          paste0("recovered_tier_", current_tier), "tested_not_supported")))]
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

# Report-level accuracy crosswalk. Prior studies predominantly reported AUROC,
# whereas the current prespecified classification metric is balanced accuracy;
# both values are retained side-by-side but must not be subtracted or treated as
# estimates of the same performance quantity.
accuracy_comparison <- out[current_status %in% c(
  "recovered_tier_A", "recovered_tier_B", "tested_not_supported"
), .(
  study, cancer = current_cancer, gene, prior_metric, prior_evidence,
  current_status, n, positive, current_balanced_accuracy, current_q,
  current_tier, source_url
)]
setorder(accuracy_comparison, current_status, cancer, gene, study)
fwrite(
  accuracy_comparison,
  "results/tables/prior_mutation_accuracy_comparison.csv"
)

# Classify every current screening-tier-A/B cancer-gene result using the
# expanded primary-study audit. This deliberately distinguishes prior support,
# prior evaluation without support, and a result not identified in the reviewed
# predictive literature; none of these labels asserts bibliographic novelty.
expanded_audit <- fread("data/reference/expanded_supported_mutation_audit.csv")
supported_mutations <- current[tier %in% c("A", "B")]
supported_mutation_audit <- merge(
  supported_mutations,
  expanded_audit,
  by.x = c("tumor_type", "endpoint"), by.y = c("cancer", "gene"),
  all.x = TRUE
)
if (nrow(supported_mutation_audit) != nrow(supported_mutations) ||
    anyNA(supported_mutation_audit$prior_evidence_class)) {
  stop("Expanded mutation literature audit is incomplete or duplicated")
}
supported_mutation_audit[, evidence_class := fcase(
  prior_evidence_class == "previously_supported",
  "previously supported in reviewed predictive literature",
  prior_evidence_class == "previously_evaluated_not_supported",
  "previously evaluated without statistical support in reviewed study",
  default = "not identified in reviewed predictive literature"
)]
supported_mutation_novelty <- supported_mutation_audit[, .(
  cancer = tumor_type, gene = endpoint, evidence_class,
  prior_study, prior_scope, prior_result, source_url, audit_note,
  n, positive,
  current_balanced_accuracy = balanced_accuracy, current_q = q_value,
  current_tier = tier
)]
setorder(supported_mutation_novelty, -current_balanced_accuracy)
fwrite(
  supported_mutation_novelty,
  "results/tables/supported_mutation_novelty.csv"
)
fwrite(
  supported_mutation_novelty,
  "results/tables/supported_mutation_literature_audit.csv"
)

status_summary <- unique(out[, .(study, prior_cancer, gene, current_status)])[, .N,
  by = current_status][order(current_status)]
fwrite(status_summary, "results/tables/prior_mutation_literature_status_summary.csv")
print(status_summary)
