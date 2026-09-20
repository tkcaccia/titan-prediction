suppressPackageStartupMessages(library(data.table))

grouped <- fread("results/tables/foundation_model_tss_grouped_sensitivity.csv")
robustness <- fread("results/tables/foundation_model_internal_robustness_classification.csv")

grouped[, `:=`(
  matched_tss_grouped_metric_name = fifelse(outcome_type == "continuous", "Q2", "AUROC"),
  matched_tss_grouped_operating_metric = fifelse(outcome_type == "continuous", grouped_q2, grouped_auc),
  matched_tss_grouped_auroc = grouped_auc,
  matched_tss_validation_scope = paste(
    "TCGA common-cohort internal validation; complete two-character tissue-source-site codes",
    "held apart in outer and inner folds; not external validation"
  ),
  matched_tss_robustness_warning = fcase(
    primary_crossing & !retained_primary_crossing,
    "Primary effect-threshold crossing was not retained after grouping by TCGA tissue-source-site code.",
    primary_crossing & retained_primary_crossing,
    "Primary effect-threshold crossing was retained after grouping; this does not establish transportability.",
    default = "This representation did not cross the primary effect threshold; grouped estimate is descriptive."
  )
)]

keep_grouped <- c(
  "foundation_model", "outcome_type", "family", "tumor_type", "endpoint",
  "primary_crossing", "grouped_crossing", "retained_primary_crossing",
  "matched_tss_grouped_metric_name", "matched_tss_grouped_operating_metric",
  "matched_tss_grouped_auroc", "grouped_effect", "matched_random_effect",
  "grouped_minus_matched_effect", "matched_tss_validation_scope",
  "matched_tss_robustness_warning", "n_codes", "realized_outer_folds",
  "outer_test_n_min", "outer_test_n_max",
  "outer_training_positive_min", "outer_training_negative_min",
  "any_single_class_outer_test_fold", "inner_folds_realized_min",
  "inner_training_positive_min", "inner_training_negative_min",
  "any_single_class_inner_training_fold",
  "grouped_fold_adequacy_flag", "grouped_fold_adequacy_reasons",
  "adequacy_flag_definition", "metric_construction"
)
g <- grouped[, ..keep_grouped]
setnames(g, c("primary_crossing", "grouped_crossing", "retained_primary_crossing",
              "grouped_effect", "matched_random_effect", "grouped_minus_matched_effect",
              "n_codes", "realized_outer_folds", "outer_test_n_min",
              "outer_test_n_max", "outer_training_positive_min",
              "outer_training_negative_min", "any_single_class_outer_test_fold",
              "inner_folds_realized_min", "inner_training_positive_min",
              "inner_training_negative_min", "any_single_class_inner_training_fold",
              "grouped_fold_adequacy_flag",
              "grouped_fold_adequacy_reasons", "adequacy_flag_definition",
              "metric_construction"),
         c("matched_tss_primary_crossing", "matched_tss_grouped_crossing",
           "matched_tss_retained_primary_crossing", "matched_tss_grouped_effect",
           "matched_tss_matched_random_effect", "matched_tss_grouped_minus_matched_effect",
           "matched_tss_n_codes", "matched_tss_realized_outer_folds",
           "matched_tss_outer_test_n_min", "matched_tss_outer_test_n_max",
           "matched_tss_outer_training_positive_min",
           "matched_tss_outer_training_negative_min",
           "matched_tss_any_single_class_outer_test_fold",
           "matched_tss_inner_folds_realized_min",
           "matched_tss_inner_training_positive_min",
           "matched_tss_inner_training_negative_min",
           "matched_tss_any_single_class_inner_training_fold",
           "matched_tss_grouped_fold_adequacy_flag",
           "matched_tss_grouped_fold_adequacy_reasons",
           "matched_tss_adequacy_flag_definition",
           "matched_tss_metric_construction"))

r <- robustness[, .(
  outcome_type, family, tumor_type, endpoint,
  matched_tss_primary_consensus_class = primary_consensus_class,
  matched_tss_sample_size_maturity = sample_size_maturity,
  matched_tss_retention_class = tss_retention_class,
  matched_tss_internal_robustness_class = internal_robustness_class
)]

attach_metadata <- function(path, default_model = NULL) {
  x <- fread(path)
  if (!"foundation_model" %in% names(x)) x[, foundation_model := default_model]
  x[, tumor_type := cancer_type]
  new_cols <- unique(c(setdiff(names(g), c("foundation_model", "outcome_type", "family", "tumor_type", "endpoint")),
                       setdiff(names(r), c("outcome_type", "family", "tumor_type", "endpoint"))))
  old_new_cols <- intersect(new_cols, names(x))
  if (length(old_new_cols)) x[, (old_new_cols) := NULL]
  x <- merge(x, g, by = c("foundation_model", "outcome_type", "family", "tumor_type", "endpoint"), all.x = TRUE, sort = FALSE)
  x <- merge(x, r, by = c("outcome_type", "family", "tumor_type", "endpoint"), all.x = TRUE, sort = FALSE)
  x[is.na(matched_tss_validation_scope), `:=`(
    matched_tss_validation_scope = "not evaluated: task was outside the primary union-positive matched task set",
    matched_tss_robustness_warning = "No matched three-representation grouped estimate: task was outside the primary union-positive set.",
    matched_tss_primary_consensus_class = "none in primary matched benchmark",
    matched_tss_retention_class = "not evaluated",
    matched_tss_internal_robustness_class = "not classified",
    matched_tss_grouped_fold_adequacy_flag = "not evaluated",
    matched_tss_grouped_fold_adequacy_reasons = "task outside grouped audit",
    matched_tss_adequacy_flag_definition = "not applicable",
    matched_tss_metric_construction = "not applicable"
  )]
  stopifnot(nrow(x) > 0L,
            all(!is.na(x$matched_tss_validation_scope)),
            all(!is.na(x$matched_tss_internal_robustness_class)))
  x[, tumor_type := NULL]
  setcolorder(x, c("foundation_model", setdiff(names(x), "foundation_model")))
  fwrite(x, path)
}

attach_metadata("models/model_registry.csv", "TITAN")
attach_metadata("models/foundation_models/model_registry_additions.csv")

message("Attached matched three-representation tissue-source-site metadata to both registries.")
