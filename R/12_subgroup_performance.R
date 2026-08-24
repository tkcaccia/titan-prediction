suppressPackageStartupMessages({
  library(data.table)
  library(readxl)
})
source("R/utils.R")
cfg <- load_project_config()

continuous <- fread("results/predictions/continuous_repeated_oof_predictions.csv.gz")
binary <- fread("results/predictions/binary_repeated_oof_predictions.csv.gz")
highlighted <- fread("results/tables/highlighted_model_performance.csv")[,
  .(family, tumor_type, endpoint, highlighted = TRUE)]

cdr <- as.data.table(read_excel(cfg$paths$tcga_cdr, na = c("", "NA"), col_types = "text"))
setnames(cdr, "bcr_patient_barcode", "patient")
unavailable <- function(x) is.na(x) | !nzchar(trimws(x)) | grepl("^\\[", trimws(x))
cdr[, recorded_sex := toupper(trimws(gender))]
cdr[unavailable(recorded_sex), recorded_sex := NA_character_]
cdr[, recorded_race := toupper(trimws(race))]
cdr[unavailable(recorded_race), recorded_race := NA_character_]
cdr[, broad_race := fcase(
  recorded_race == "WHITE", "White",
  recorded_race == "BLACK OR AFRICAN AMERICAN", "Black or African American",
  recorded_race == "ASIAN", "Asian",
  !is.na(recorded_race), "Other recorded race",
  default = NA_character_
)]
cdr <- cdr[, .(patient, recorded_sex, broad_race)]

auc_rank <- function(y, score) {
  pos <- score[y == 1]; neg <- score[y == 0]
  if (!length(pos) || !length(neg)) return(NA_real_)
  (sum(rank(c(pos, neg), ties.method = "average")[seq_along(pos)]) -
     length(pos) * (length(pos) + 1) / 2) / (length(pos) * length(neg))
}
average_precision <- function(y, score) {
  if (!any(y == 1) || !any(y == 0)) return(NA_real_)
  o <- order(score, decreasing = TRUE)
  y <- y[o]
  mean((cumsum(y) / seq_along(y))[y == 1])
}

metric_continuous <- function(z) {
  den <- sum((z$observed - mean(z$observed))^2)
  data.table(
    q2 = if (den > 0) 1 - sum((z$observed - z$predicted)^2) / den else NA_real_,
    rmse = sqrt(mean((z$observed - z$predicted)^2)),
    spearman = suppressWarnings(cor(z$observed, z$predicted, method = "spearman"))
  )
}
metric_binary <- function(z) {
  tp <- sum(z$observed == 1 & z$predicted == 1); fn <- sum(z$observed == 1 & z$predicted == 0)
  tn <- sum(z$observed == 0 & z$predicted == 0); fp <- sum(z$observed == 0 & z$predicted == 1)
  sensitivity <- if (tp + fn) tp / (tp + fn) else NA_real_
  specificity <- if (tn + fp) tn / (tn + fp) else NA_real_
  data.table(
    sensitivity = sensitivity, specificity = specificity,
    balanced_accuracy = mean(c(sensitivity, specificity)),
    auc = auc_rank(z$observed, z$lda_score),
    pr_auc = average_precision(z$observed, z$lda_score)
  )
}

make_rows <- function(d, outcome_type) {
  d <- merge(d, cdr, by = "patient", all.x = TRUE)
  d[, model_n := uniqueN(patient), by = .(family, tumor_type, endpoint)]
  d[, high_volume := model_n >= 200L]
  d[, recorded_sex := fifelse(is.na(recorded_sex), "Missing", recorded_sex)]
  d[, broad_race := fifelse(is.na(broad_race), "Missing", broad_race)]
  long <- rbindlist(list(
    d[, .(family, tumor_type, endpoint, repeat_id = get("repeat"), patient, observed, predicted,
          lda_score = if ("lda_score" %in% names(d)) lda_score else NA_real_,
          model_n, high_volume, subgroup_variable = "Recorded sex", subgroup = recorded_sex)],
    d[, .(family, tumor_type, endpoint, repeat_id = get("repeat"), patient, observed, predicted,
          lda_score = if ("lda_score" %in% names(d)) lda_score else NA_real_,
          model_n, high_volume, subgroup_variable = "Broad race", subgroup = broad_race)]
  ))
  counts <- unique(long[, .(family, tumor_type, endpoint, subgroup_variable, subgroup,
                           model_n, high_volume, patient, observed)])[, .(
    subgroup_n = .N,
    positive = if (outcome_type == "binary") sum(observed == 1) else NA_integer_,
    negative = if (outcome_type == "binary") sum(observed == 0) else NA_integer_
  ), by = .(family, tumor_type, endpoint, subgroup_variable, subgroup, model_n, high_volume)]
  counts[, denominator_adequate := high_volume & subgroup != "Missing" &
    if (outcome_type == "binary") positive >= 20L & negative >= 20L else subgroup_n >= 50L]
  counts[, reason := fcase(
    !high_volume, "model has fewer than 200 outcome-labelled patients",
    subgroup == "Missing", "demographic field missing",
    outcome_type == "continuous" & subgroup_n < 50L, "fewer than 50 subgroup patients",
    outcome_type == "binary" & positive < 20L & negative < 20L, "fewer than 20 positive and 20 negative subgroup patients",
    outcome_type == "binary" & positive < 20L, "fewer than 20 positive subgroup patients",
    outcome_type == "binary" & negative < 20L, "fewer than 20 negative subgroup patients",
    default = "performance estimated"
  )]
  eligible <- merge(long, counts[denominator_adequate == TRUE,
    .(family, tumor_type, endpoint, subgroup_variable, subgroup)],
    by = c("family", "tumor_type", "endpoint", "subgroup_variable", "subgroup"))
  if (nrow(eligible)) {
    metrics <- eligible[, if (outcome_type == "binary") metric_binary(.SD) else metric_continuous(.SD),
      by = .(family, tumor_type, endpoint, subgroup_variable, subgroup, repeat_id)]
    metrics <- metrics[, lapply(.SD, mean, na.rm = TRUE),
      by = .(family, tumor_type, endpoint, subgroup_variable, subgroup),
      .SDcols = setdiff(names(metrics), c("family", "tumor_type", "endpoint", "subgroup_variable", "subgroup", "repeat_id"))]
    counts <- merge(counts, metrics, by = c("family", "tumor_type", "endpoint", "subgroup_variable", "subgroup"), all.x = TRUE)
  }
  counts[, outcome_type := outcome_type]
  counts
}

subgroups <- rbindlist(list(
  make_rows(continuous, "continuous"),
  make_rows(binary, "binary")
), fill = TRUE)
subgroups <- merge(subgroups, highlighted, by = c("family", "tumor_type", "endpoint"), all.x = TRUE)
subgroups[is.na(highlighted), highlighted := FALSE]
setcolorder(subgroups, c("outcome_type", "family", "tumor_type", "endpoint", "highlighted",
  "model_n", "high_volume", "subgroup_variable", "subgroup", "subgroup_n", "positive",
  "negative", "denominator_adequate", "reason", "q2", "rmse", "spearman", "sensitivity",
  "specificity", "balanced_accuracy", "auc", "pr_auc"))
setorder(subgroups, -highlighted, outcome_type, family, tumor_type, endpoint, subgroup_variable, subgroup)
fwrite(subgroups, "results/tables/subgroup_performance_audit.csv")

summary <- subgroups[, .(
  models = uniqueN(paste(family, tumor_type, endpoint, sep = "__")),
  high_volume_models = uniqueN(paste(family[high_volume], tumor_type[high_volume], endpoint[high_volume], sep = "__")),
  estimable_subgroup_rows = sum(denominator_adequate),
  nonestimable_subgroup_rows = sum(!denominator_adequate)
), by = .(outcome_type, subgroup_variable)]
fwrite(summary, "results/tables/subgroup_performance_summary.csv")

sex <- subgroups[denominator_adequate == TRUE & subgroup_variable == "Recorded sex" &
                   subgroup %in% c("FEMALE", "MALE")]
sex_wide <- dcast(sex, outcome_type + family + tumor_type + endpoint ~ subgroup,
                  value.var = c("q2", "balanced_accuracy", "auc"))
race_white <- subgroups[denominator_adequate == TRUE & subgroup_variable == "Broad race" & subgroup == "White"]
race_other <- subgroups[denominator_adequate == TRUE & subgroup_variable == "Broad race" &
                          !subgroup %in% c("White", "Missing")]
race_pairs <- merge(race_white, race_other,
  by = c("outcome_type", "family", "tumor_type", "endpoint"), suffixes = c("_white", "_other"))
contrast_summary <- rbindlist(list(
  data.table(contrast = "Female versus male", outcome_type = "continuous",
    comparisons = sum(is.finite(sex_wide$q2_FEMALE) & is.finite(sex_wide$q2_MALE)),
    primary_metric = "Q2", median_absolute_difference = median(abs(sex_wide$q2_FEMALE - sex_wide$q2_MALE), na.rm = TRUE)),
  data.table(contrast = "Female versus male", outcome_type = "binary",
    comparisons = sum(is.finite(sex_wide$auc_FEMALE) & is.finite(sex_wide$auc_MALE)),
    primary_metric = "AUROC", median_absolute_difference = median(abs(sex_wide$auc_FEMALE - sex_wide$auc_MALE), na.rm = TRUE),
    median_absolute_balanced_accuracy_difference = median(abs(sex_wide$balanced_accuracy_FEMALE - sex_wide$balanced_accuracy_MALE), na.rm = TRUE)),
  data.table(contrast = "White versus each estimable non-White category", outcome_type = "continuous",
    comparisons = sum(is.finite(race_pairs$q2_white) & is.finite(race_pairs$q2_other)),
    primary_metric = "Q2", median_absolute_difference = median(abs(race_pairs$q2_white - race_pairs$q2_other), na.rm = TRUE)),
  data.table(contrast = "White versus each estimable non-White category", outcome_type = "binary",
    comparisons = sum(is.finite(race_pairs$auc_white) & is.finite(race_pairs$auc_other)),
    primary_metric = "AUROC", median_absolute_difference = median(abs(race_pairs$auc_white - race_pairs$auc_other), na.rm = TRUE),
    median_absolute_balanced_accuracy_difference = median(abs(race_pairs$balanced_accuracy_white - race_pairs$balanced_accuracy_other), na.rm = TRUE))
), fill = TRUE)
fwrite(contrast_summary, "results/tables/subgroup_performance_contrast_summary.csv")
cat("subgroup audit:", nrow(subgroups), "model-subgroup rows;",
    uniqueN(subgroups[high_volume == TRUE, paste(family, tumor_type, endpoint)]),
    "high-volume models;", sum(subgroups$denominator_adequate), "estimable rows\n")
