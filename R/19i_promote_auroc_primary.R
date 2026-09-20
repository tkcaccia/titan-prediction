.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages(library(data.table))

# Promote the coherent AUROC-centred binary estimand into the matched atlas.
# Component counts are selected by pooled inner out-of-fold AUROC. Outer
# out-of-fold AUROC defines the primary binary effect and the 0.60 crossing.
# Operating-point metrics use a balanced-accuracy threshold learned only from
# the corresponding outer training set.
screen_path <- "results/tables/foundation_model_matched_screen.csv"
auroc_path <- "results/tables/foundation_model_binary_auroc_tuned_sensitivity.csv"
oof_path <- "results/predictions/foundation_model_matched_oof.rds"
auroc_oof_path <- "results/predictions/foundation_model_binary_auroc_tuned_oof.rds"
stopifnot(file.exists(screen_path), file.exists(auroc_path),
          file.exists(oof_path), file.exists(auroc_oof_path))

screen <- fread(screen_path)
auroc <- fread(auroc_path)
keys <- c("foundation_model", "family", "tumor_type", "endpoint")
binary_index <- which(screen$outcome_type == "binary")
if (nrow(auroc) != length(binary_index)) {
  stop("AUROC result count does not match the matched binary atlas")
}
key_string <- function(d) do.call(paste, c(d[, ..keys], sep = "\r"))
position <- match(key_string(screen[binary_index]), key_string(auroc))
if (anyNA(position) || anyDuplicated(key_string(auroc))) {
  stop("AUROC result identities do not match the binary atlas")
}

baseline_path <- "results/tables/foundation_model_matched_screen_empirical_ba_reference.csv"
if (!file.exists(baseline_path)) fwrite(screen, baseline_path)

mapping <- c(
  balanced_accuracy = "balanced_accuracy",
  auc = "auroc",
  pr_auc = "pr_auc",
  sensitivity = "sensitivity",
  specificity = "specificity",
  ppv = "ppv",
  npv = "npv",
  prevalence = "prevalence",
  no_skill_pr_auc = "no_skill_pr_auc",
  selected_components_median = "median_selected_component",
  selected_components_min = "minimum_selected_component",
  selected_components_max = "maximum_selected_component",
  selected_components_at_ceiling = "components_at_ceiling",
  selected_components_ceiling_fraction = "components_at_ceiling"
)
for (destination in names(mapping)) {
  source <- unname(mapping[[destination]])
  values <- auroc[[source]][position]
  if (destination == "selected_components_ceiling_fraction") values <- values / 5
  set(screen, i = binary_index, j = destination, value = values)
}
set(screen, i = binary_index, j = "selected_components_outer_fits", value = 5L)
set(screen, i = binary_index, j = "operating_threshold_median",
    value = auroc$median_selected_threshold[position])
set(screen, i = binary_index, j = "primary_binary_tuning_objective",
    value = "pooled inner out-of-fold AUROC")
set(screen, i = binary_index, j = "primary_binary_metric",
    value = "outer out-of-fold AUROC")
set(screen, i = binary_index, j = "binary_crossing_rule",
    value = "AUROC >= 0.60")
set(screen, i = binary_index, j = "binary_operating_threshold_rule",
    value = paste(
      "balanced-accuracy optimum learned from pooled inner out-of-fold",
      "training scores; applied unchanged to the outer test fold"
    ))
set(screen, i = binary_index, j = "primary_binary_decision_rule",
    value = paste(
      "PLS component selected by inner AUROC; binary operating threshold",
      "selected inside the outer training data"
    ))
set(screen, i = binary_index, j = "decision_rule_sensitivity_scope",
    value = paste(
      "empirical-prior, equal-prior and training-only threshold calls",
      "compared on identical AUROC-selected components and outer scores"
    ))
set(screen, i = binary_index, j = "decision_rule_sensitivity_status",
    value = "reported as secondary operating-point sensitivity")
setorder(screen, foundation_model, outcome_type, family, tumor_type, endpoint)
fwrite(screen, screen_path)

# Replace binary OOF rows with the AUROC-tuned scores and training-only calls.
old_oof <- as.data.table(readRDS(oof_path))
new_oof <- as.data.table(readRDS(auroc_oof_path))
metadata <- unique(screen[outcome_type == "binary", .(
  foundation_model, family, tumor_type, endpoint, subfamily, source
)])
new_oof <- merge(new_oof, metadata,
  by = c("foundation_model", "family", "tumor_type", "endpoint"),
  all.x = TRUE, sort = FALSE)
new_oof[, `:=`(
  predicted = NA_real_,
  outcome_type = "binary"
)]
matched_oof <- rbindlist(list(
  old_oof[outcome_type == "continuous"], new_oof
), use.names = TRUE, fill = TRUE)
setorder(matched_oof, foundation_model, outcome_type, family, tumor_type,
         endpoint, patient)
saveRDS(matched_oof, oof_path, compress = "xz")

# Continuous paired operating-rule changes on identical AUROC-selected scores.
operating <- rbindlist(list(
  auroc[, .(
    foundation_model, family, tumor_type, endpoint, n, positive, negative,
    prevalence, no_skill_pr_auc, rule = "empirical training priors",
    balanced_accuracy = empirical_prior_balanced_accuracy,
    sensitivity = empirical_prior_sensitivity,
    specificity = empirical_prior_specificity,
    ppv = empirical_prior_ppv, npv = empirical_prior_npv,
    auroc, pr_auc
  )],
  auroc[, .(
    foundation_model, family, tumor_type, endpoint, n, positive, negative,
    prevalence, no_skill_pr_auc, rule = "equal class priors",
    balanced_accuracy = equal_prior_balanced_accuracy,
    sensitivity = equal_prior_sensitivity,
    specificity = equal_prior_specificity,
    ppv = equal_prior_ppv, npv = equal_prior_npv,
    auroc, pr_auc
  )],
  auroc[, .(
    foundation_model, family, tumor_type, endpoint, n, positive, negative,
    prevalence, no_skill_pr_auc, rule = "training-only optimized threshold",
    balanced_accuracy, sensitivity, specificity, ppv, npv, auroc, pr_auc
  )]
), use.names = TRUE)
operating[, ba_crossing_sensitivity := balanced_accuracy >= 0.60]
empirical <- operating[rule == "empirical training priors", .(
  foundation_model, family, tumor_type, endpoint,
  empirical_balanced_accuracy = balanced_accuracy,
  empirical_sensitivity = sensitivity,
  empirical_specificity = specificity,
  empirical_ppv = ppv, empirical_npv = npv
)]
operating <- merge(operating, empirical,
  by = c("foundation_model", "family", "tumor_type", "endpoint"),
  all.x = TRUE, sort = FALSE)
for (metric in c("balanced_accuracy", "sensitivity", "specificity", "ppv", "npv")) {
  operating[, (paste0(metric, "_delta_vs_empirical")) :=
    get(metric) - get(paste0("empirical_", metric))]
}
fwrite(operating,
       "results/tables/foundation_model_binary_operating_rule_metrics.csv")

operating_summary <- operating[, .(
  tasks = .N,
  ba_crossings_for_sensitivity = sum(ba_crossing_sensitivity, na.rm = TRUE),
  median_balanced_accuracy = median(balanced_accuracy, na.rm = TRUE),
  median_ba_delta_vs_empirical = median(
    balanced_accuracy_delta_vs_empirical, na.rm = TRUE
  ),
  q25_ba_delta_vs_empirical = quantile(
    balanced_accuracy_delta_vs_empirical, 0.25, na.rm = TRUE
  ),
  q75_ba_delta_vs_empirical = quantile(
    balanced_accuracy_delta_vs_empirical, 0.75, na.rm = TRUE
  ),
  median_sensitivity_delta_vs_empirical = median(
    sensitivity_delta_vs_empirical, na.rm = TRUE
  ),
  median_specificity_delta_vs_empirical = median(
    specificity_delta_vs_empirical, na.rm = TRUE
  ),
  median_ppv_delta_vs_empirical = median(ppv_delta_vs_empirical, na.rm = TRUE),
  median_npv_delta_vs_empirical = median(npv_delta_vs_empirical, na.rm = TRUE),
  median_auroc = median(auroc, na.rm = TRUE),
  median_pr_auc = median(pr_auc, na.rm = TRUE),
  median_prevalence = median(prevalence, na.rm = TRUE)
), by = .(foundation_model, rule)]
fwrite(operating_summary,
       "results/tables/foundation_model_binary_operating_rule_paired_summary.csv")

# Synchronise the controlled alternative-representation registry when it is
# present. The fitted objects themselves are regenerated by R/17 using this
# promoted matched screen.
registry_path <- "models/foundation_models/model_registry_additions.csv"
if (file.exists(registry_path)) {
  registry <- fread(registry_path)
  registry_binary <- which(registry$outcome_type == "binary")
  registry_keys <- paste(
    registry$foundation_model[registry_binary], registry$family[registry_binary],
    registry$cancer_type[registry_binary], registry$endpoint[registry_binary],
    sep = "\r"
  )
  screen_binary <- screen[outcome_type == "binary"]
  screen_keys <- key_string(screen_binary)
  registry_position <- match(registry_keys, screen_keys)
  if (anyNA(registry_position)) {
    stop("A controlled binary object is absent from the promoted matched screen")
  }
  registry_mapping <- c(
    screen_balanced_accuracy = "balanced_accuracy",
    screen_auc = "auc", binary_pr_auc = "pr_auc",
    screen_sensitivity = "sensitivity", screen_specificity = "specificity",
    screen_ppv = "ppv", screen_npv = "npv",
    binary_prevalence = "prevalence",
    binary_no_skill_pr_auc = "no_skill_pr_auc",
    binary_operating_threshold_median = "operating_threshold_median"
  )
  for (destination in names(registry_mapping)) {
    source <- unname(registry_mapping[[destination]])
    set(registry, i = registry_binary, j = destination,
        value = screen_binary[[source]][registry_position])
  }
  crossed <- screen_binary$auc[registry_position] >= 0.60
  mature <- pmin(registry$positive[registry_binary],
                 registry$negative[registry_binary]) >= 50L
  set(registry, i = registry_binary,
      j = "representation_effect_threshold_crossing", value = crossed)
  set(registry, i = registry_binary, j = "default_inference",
      value = crossed & mature)
  set(registry, i = registry_binary, j = "primary_binary_metric",
      value = "outer out-of-fold AUROC")
  set(registry, i = registry_binary, j = "binary_crossing_rule",
      value = "AUROC >= 0.60")
  set(registry, i = registry_binary, j = "primary_binary_decision_rule",
      value = paste(
        "component selected by pooled inner out-of-fold AUROC; operating",
        "threshold selected inside each outer training set"
      ))
  setorder(registry, foundation_model, outcome_type, family, cancer_type, endpoint)
  fwrite(registry, registry_path)
}

cat("Promoted AUROC-centred binary estimand for", length(binary_index),
    "representation-task rows\n")
