.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
  library(ggplot2)
  library(patchwork)
})
source("R/utils.R")
cfg <- load_project_config()
options(backend = tolower(Sys.getenv("TITAN_BACKEND", "cpu")))

# Fold and threshold stability audit for the matched representation atlas.
model_names <- c("TITAN", "GigaSSL", "ProvGigaPath")
n_repeats <- as.integer(Sys.getenv("FMPRED_STABILITY_REPEATS", "5"))
if (!is.finite(n_repeats) || n_repeats < 2L) {
  stop("FMPRED_STABILITY_REPEATS must be at least 2")
}
continuous_threshold <- 0.20
binary_threshold <- 0.60
continuous_near_half_width <- 0.05
binary_near_half_width <- 0.05

primary <- fread("results/tables/foundation_model_matched_screen.csv")
comparison <- fread("results/tables/foundation_model_target_comparison.csv")
task_id <- c("outcome_type", "family", "subfamily", "tumor_type", "endpoint", "source")

comparison[, primary_near_threshold := ifelse(
  outcome_type == "continuous",
  apply(abs(cbind(q2_TITAN, q2_GigaSSL, q2_ProvGigaPath) -
              continuous_threshold) <= continuous_near_half_width, 1L, any),
  apply(abs(cbind(auc_TITAN, auc_GigaSSL,
                  auc_ProvGigaPath) - binary_threshold) <=
              binary_near_half_width, 1L, any)
)]
comparison[, primary_union_positive := supported_by_n > 0L]
selection <- comparison[primary_union_positive | primary_near_threshold]
selection[, selection_reason := fcase(
  primary_union_positive & primary_near_threshold,
  "union-positive and near-threshold",
  primary_union_positive, "union-positive",
  default = "near-threshold only"
)]
selection[, primary_consensus_class := fcase(
  supported_by_n == 3L, "all three",
  supported_by_n == 2L, "exactly two",
  supported_by_n == 1L, "representation specific",
  default = "none"
)]
selection[, primary_threshold_distance_min := ifelse(
  outcome_type == "continuous",
  apply(abs(cbind(q2_TITAN, q2_GigaSSL, q2_ProvGigaPath) -
              continuous_threshold), 1L, min),
  apply(abs(cbind(auc_TITAN, auc_GigaSSL,
                  auc_ProvGigaPath) - binary_threshold), 1L, min)
)]
setorder(selection, outcome_type, family, tumor_type, endpoint)
selection[, stability_job_id := .I]
fwrite(selection, "results/tables/foundation_model_fold_stability_selection.csv")

cohorts <- setNames(lapply(model_names, function(model) {
  readRDS(file.path("data/processed", paste0("patient_cohort_", model, ".rds")))
}), model_names)
common_patients <- Reduce(intersect, lapply(cohorts, function(x) rownames(x$X)))
continuous <- readRDS("data/processed/continuous_targets.rds")[patient %chin% common_patients]
binary <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)[patient %chin% common_patients]

work <- CJ(stability_job_id = selection$stability_job_id,
           stability_repeat = seq_len(n_repeats))
setorder(work, stability_job_id, stability_repeat)
limit <- as.integer(Sys.getenv("FMPRED_STABILITY_JOB_LIMIT", "0"))
if (is.finite(limit) && limit > 0L) work <- work[seq_len(min(limit, .N))]

checkpoint_dir <- file.path(
  "data/processed/checkpoints",
  paste0("foundation_model_fold_stability_auroc_r", n_repeats)
)
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)
fastpls_description <- packageDescription("fastPLS")
fingerprint <- digest::digest(list(
  schema = 2L,
  specification = "five-alternative-partition matched audit; union-positive or within 0.05 of Q2=0.20/AUROC=0.60; binary components selected by pooled inner OOF AUROC",
  utils = digest::digest(file = "R/utils.R", algo = "sha256"),
  primary = digest::digest(file = "results/tables/foundation_model_matched_screen.csv", algo = "sha256"),
  comparison = digest::digest(file = "results/tables/foundation_model_target_comparison.csv", algo = "sha256"),
  cohorts = vapply(cohorts, `[[`, character(1), "source_sha256"),
  continuous = digest::digest(file = "data/processed/continuous_targets.rds", algo = "sha256"),
  binary_nonmutation = digest::digest(file = "data/processed/binary_targets_nonmutation.rds", algo = "sha256"),
  binary_mutation = digest::digest(file = "data/processed/binary_targets_mutation.rds", algo = "sha256"),
  analysis = cfg$analysis,
  repeats = n_repeats,
  selected_task_keys = selection[, do.call(paste, c(.SD, sep = "\r")), .SDcols = task_id],
  fastPLS_version = as.character(packageVersion("fastPLS")),
  fastPLS_remote_sha = as.character(fastpls_description$RemoteSha)
), algo = "sha256")

checkpoint_path <- function(job_id, repeat_id) file.path(
  checkpoint_dir, sprintf("job_%04d_repeat_%02d.rds", job_id, repeat_id)
)
checkpoint_current <- function(path) {
  if (!file.exists(path)) return(FALSE)
  z <- tryCatch(readRDS(path), error = function(e) NULL)
  !is.null(z) && identical(z$fingerprint, fingerprint)
}

run_one <- function(i) {
  item <- work[i]
  path <- checkpoint_path(item$stability_job_id, item$stability_repeat)
  if (checkpoint_current(path)) return(NULL)
  job <- selection[stability_job_id == item$stability_job_id]
  targets <- if (job$outcome_type == "continuous") continuous else binary
  d <- targets[family == job$family & tumor_type == job$tumor_type &
                 endpoint == job$endpoint & source == job$source]
  if (job$outcome_type == "continuous") {
    d <- d[is.finite(value)]
  } else {
    d <- d[value %in% c(0L, 1L)]
  }
  setorder(d, patient)
  y <- if (job$outcome_type == "continuous") {
    d$value
  } else {
    factor(d$value, levels = c(0L, 1L))
  }
  # A large offset keeps these alternative partitions distinct from the
  # primary atlas. The task and repeat seed is reused for every representation.
  seed <- cfg$analysis$seed + 500000L +
    item$stability_repeat * 10000L + item$stability_job_id
  rows <- list()
  predictions <- list()
  reference_fold <- NULL
  for (model in model_names) {
    idx <- match(d$patient, rownames(cohorts[[model]]$X))
    stopifnot(!anyNA(idx))
    X <- cohorts[[model]]$X[idx, , drop = FALSE]
    if (job$outcome_type == "continuous") {
      fit <- fit_continuous_nested_once(X, y, cfg$analysis, seed)
      rows[[model]] <- data.table(
        foundation_model = model,
        q2 = fit$q2,
        rmse = fit$rmse,
        spearman = fit$correlation,
        sensitivity = NA_real_,
        specificity = NA_real_,
        balanced_accuracy = NA_real_,
        auc = NA_real_,
        pr_auc = NA_real_,
        crossing = is.finite(fit$q2) && fit$q2 >= continuous_threshold,
        selected_components_median = median(fit$ncomp),
        selected_components_min = min(fit$ncomp),
        selected_components_max = max(fit$ncomp),
        selected_components_ceiling_fraction = mean(fit$ncomp == max(cfg$analysis$components))
      )
      predictions[[model]] <- data.table(
        foundation_model = model, patient = d$patient, observed = as.numeric(y),
        predicted = fit$prediction, predicted_class = NA_integer_,
        score = NA_real_, outer_fold = fit$fold
      )
    } else {
      fit <- fit_binary_nested_auroc_once(X, y, cfg$analysis, seed)
      metrics <- binary_classification_metrics(y, fit$prediction, fit$score)
      rows[[model]] <- data.table(
        foundation_model = model,
        q2 = NA_real_,
        rmse = NA_real_,
        spearman = NA_real_,
        sensitivity = metrics$sensitivity,
        specificity = metrics$specificity,
        balanced_accuracy = metrics$balanced_accuracy,
        auc = metrics$auc,
        pr_auc = average_precision(y, fit$score),
        ppv = metrics$ppv,
        npv = metrics$npv,
        prevalence = metrics$prevalence,
        no_skill_pr_auc = metrics$no_skill_pr_auc,
        crossing = is.finite(metrics$auc) && metrics$auc >= binary_threshold,
        selected_components_median = median(fit$ncomp),
        selected_components_min = min(fit$ncomp),
        selected_components_max = max(fit$ncomp),
        selected_components_ceiling_fraction = mean(fit$ncomp == max(cfg$analysis$components))
      )
      predictions[[model]] <- data.table(
        foundation_model = model, patient = d$patient,
        observed = as.integer(as.character(y)), predicted = NA_real_,
        predicted_class = as.integer(as.character(fit$prediction)),
        score = fit$score, outer_fold = fit$fold
      )
    }
    if (is.null(reference_fold)) reference_fold <- fit$fold
    if (!identical(reference_fold, fit$fold)) {
      stop("Matched-fold invariant failed for ", model, " in job ",
           item$stability_job_id, ", repeat ", item$stability_repeat)
    }
  }
  fold_audit <- data.table(
    stability_job_id = item$stability_job_id,
    stability_repeat = item$stability_repeat,
    seed = seed,
    fold_assignment_sha256 = digest::digest(
      paste(d$patient, reference_fold, sep = "="), algo = "sha256"
    ),
    outer_fold_n = paste(tabulate(reference_fold, nbins = cfg$analysis$outer_folds),
                         collapse = ";"),
    outer_fold_positive = if (job$outcome_type == "binary") paste(
      vapply(seq_len(cfg$analysis$outer_folds), function(fold) {
        sum(as.character(y[reference_fold == fold]) == "1")
      }, integer(1)), collapse = ";") else NA_character_,
    outer_fold_negative = if (job$outcome_type == "binary") paste(
      vapply(seq_len(cfg$analysis$outer_folds), function(fold) {
        sum(as.character(y[reference_fold == fold]) == "0")
      }, integer(1)), collapse = ";") else NA_character_,
    identical_across_representations = TRUE
  )
  result <- rbindlist(rows, fill = TRUE)
  result[, `:=`(
    stability_job_id = item$stability_job_id,
    stability_repeat = item$stability_repeat,
    outcome_type = job$outcome_type,
    family = job$family,
    subfamily = job$subfamily,
    tumor_type = job$tumor_type,
    endpoint = job$endpoint,
    source = job$source,
    n = nrow(d),
    positive = if (job$outcome_type == "binary") sum(as.character(y) == "1") else NA_integer_,
    negative = if (job$outcome_type == "binary") sum(as.character(y) == "0") else NA_integer_,
    seed = seed,
    effect = ifelse(job$outcome_type == "continuous", q2, auc),
    primary_union_positive = job$primary_union_positive,
    primary_near_threshold = job$primary_near_threshold,
    selection_reason = job$selection_reason,
    fastPLS_version = as.character(packageVersion("fastPLS")),
    fastPLS_remote_sha = as.character(fastpls_description$RemoteSha)
  )]
  prediction <- rbindlist(predictions, fill = TRUE)
  prediction[, `:=`(
    stability_job_id = item$stability_job_id,
    stability_repeat = item$stability_repeat,
    outcome_type = job$outcome_type,
    family = job$family,
    subfamily = job$subfamily,
    tumor_type = job$tumor_type,
    endpoint = job$endpoint,
    source = job$source
  )]
  tmp <- paste0(path, ".tmp-", Sys.getpid())
  saveRDS(list(fingerprint = fingerprint, result = result,
               prediction = prediction, fold_audit = fold_audit),
          tmp, compress = "xz")
  file.rename(tmp, path)
  NULL
}

workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
if (!is.finite(workers) || workers < 1L) workers <- 1L
if (workers == 1L) {
  for (i in seq_len(nrow(work))) {
    run_one(i)
    if (i %% 10L == 0L || i == nrow(work)) {
      cat("Completed or resumed", i, "of", nrow(work), "task-repeat fits\n")
      flush.console()
    }
  }
} else {
  future::plan(future::multicore, workers = workers)
  invisible(future_lapply(seq_len(nrow(work)), run_one, future.seed = TRUE,
                          future.packages = c("fastPLS", "data.table", "digest"),
                          future.globals = TRUE, future.chunk.size = 1))
}

expected <- mapply(checkpoint_path, work$stability_job_id, work$stability_repeat,
                   USE.NAMES = FALSE)
if (!all(file.exists(expected))) stop("Fold-stability checkpoint missing")
objects <- lapply(expected, readRDS)
if (!all(vapply(objects, function(z) identical(z$fingerprint, fingerprint), logical(1)))) {
  stop("Stale fold-stability checkpoint detected")
}
repeats <- rbindlist(lapply(objects, `[[`, "result"), fill = TRUE)
oof <- rbindlist(lapply(objects, `[[`, "prediction"), fill = TRUE)
fold_audit <- rbindlist(lapply(objects, `[[`, "fold_audit"), fill = TRUE)
# Recompute the probe-comparison statistic row-wise after binding. The
# task-level outcome type is scalar inside each checkpoint, whereas each
# checkpoint contains three representation rows.
repeats[, effect := fifelse(outcome_type == "continuous", q2, auc)]
setorder(repeats, outcome_type, family, tumor_type, endpoint,
         stability_repeat, foundation_model)
fwrite(repeats, "results/tables/foundation_model_fold_stability_repeats.csv")
saveRDS(oof, "results/predictions/foundation_model_fold_stability_oof.rds",
        compress = "xz")
fwrite(fold_audit, "results/tables/foundation_model_fold_assignment_audit.csv")

primary_long <- primary[, .(
  outcome_type, family, subfamily, tumor_type, endpoint, source,
  foundation_model,
  primary_q2 = q2,
  primary_balanced_accuracy = balanced_accuracy,
  primary_auc = auc,
  primary_effect = fifelse(outcome_type == "continuous", q2, auc),
  primary_crossing_statistic = fifelse(outcome_type == "continuous", q2, auc),
  primary_crossing = fifelse(outcome_type == "continuous", q2 >= continuous_threshold,
                             auc >= binary_threshold)
)]
crossing_stability <- repeats[, .(
  alternative_partitions = .N,
  crossing_count = sum(crossing),
  crossing_proportion = mean(crossing),
  mean_effect = mean(effect, na.rm = TRUE),
  sd_effect = sd(effect, na.rm = TRUE),
  median_effect = median(effect, na.rm = TRUE),
  min_effect = min(effect, na.rm = TRUE),
  max_effect = max(effect, na.rm = TRUE),
  mean_q2 = mean(q2, na.rm = TRUE),
  mean_balanced_accuracy = mean(balanced_accuracy, na.rm = TRUE),
  mean_auc = mean(auc, na.rm = TRUE),
  mean_pr_auc = mean(pr_auc, na.rm = TRUE),
  mean_ppv = mean(ppv, na.rm = TRUE),
  mean_npv = mean(npv, na.rm = TRUE),
  mean_prevalence = mean(prevalence, na.rm = TRUE),
  selected_components_median = median(selected_components_median),
  component_ceiling_fraction = mean(selected_components_ceiling_fraction)
), by = c(task_id, "foundation_model", "selection_reason",
          "primary_union_positive", "primary_near_threshold")]
crossing_stability <- merge(crossing_stability, primary_long,
                            by = c(task_id, "foundation_model"), all.x = TRUE)
crossing_stability[, primary_repeat_crossing_agreement_proportion := ifelse(
  primary_crossing, crossing_proportion, 1 - crossing_proportion
)]
setorder(crossing_stability, outcome_type, family, tumor_type, endpoint,
         foundation_model)
fwrite(crossing_stability,
       "results/tables/foundation_model_crossing_stability.csv")

repeat_wide <- dcast(repeats, paste(paste(c(task_id, "stability_job_id",
                                           "stability_repeat"), collapse = " + "),
                                    "~ foundation_model"),
                     value.var = c("crossing", "effect"))
repeat_wide[, supported_by_n := rowSums(.SD), .SDcols = patterns("^crossing_")]
repeat_wide[, consensus_class := fcase(
  supported_by_n == 3L, "all three",
  supported_by_n == 2L, "exactly two",
  supported_by_n == 1L, "representation specific",
  default = "none"
)]
repeat_wide[, support_pattern := paste0(
  fifelse(crossing_TITAN, "TITAN", ""),
  fifelse(crossing_GigaSSL, "+GigaSSL", ""),
  fifelse(crossing_ProvGigaPath, "+ProvGigaPath", "")
)]
repeat_wide[, support_pattern := sub("^\\+", "", support_pattern)]
repeat_wide[support_pattern == "", support_pattern := "None"]
repeat_wide[, `:=`(
  rank_TITAN = frank(-effect_TITAN, ties.method = "average"),
  rank_GigaSSL = frank(-effect_GigaSSL, ties.method = "average"),
  rank_ProvGigaPath = frank(-effect_ProvGigaPath, ties.method = "average")
), by = .(outcome_type, stability_repeat)]

primary_best <- selection[, c(task_id, "best_foundation_model"), with = FALSE]
repeat_wide <- merge(repeat_wide, primary_best, by = task_id, all.x = TRUE)
repeat_wide[, repeat_best_foundation_model :=
  c("GigaSSL", "ProvGigaPath", "TITAN")[
    max.col(cbind(effect_GigaSSL, effect_ProvGigaPath, effect_TITAN),
            ties.method = "first")
  ]]
winner_stability <- repeat_wide[, {
  z <- sort(table(repeat_best_foundation_model), decreasing = TRUE)
  list(
    primary_best_foundation_model = best_foundation_model[1L],
    alternative_partitions = .N,
    primary_winner_repeat_count = sum(
      repeat_best_foundation_model == best_foundation_model[1L]
    ),
    primary_winner_repeat_proportion = mean(
      repeat_best_foundation_model == best_foundation_model[1L]
    ),
    modal_repeat_winner = names(z)[1L],
    modal_repeat_winner_count = as.integer(z[1L]),
    modal_repeat_winner_proportion = as.numeric(z[1L]) / .N,
    modal_repeat_winner_tied = sum(z == z[1L]) > 1L
  )
}, by = task_id]
fwrite(winner_stability,
       "results/tables/foundation_model_winner_stability.csv")

pairwise_repeat <- rbindlist(lapply(c("GigaSSL", "ProvGigaPath"), function(other) {
  repeat_wide[, .(
    targets = .N,
    median_delta_vs_TITAN = median(get(paste0("effect_", other)) - effect_TITAN),
    q1_delta_vs_TITAN = quantile(get(paste0("effect_", other)) - effect_TITAN, 0.25),
    q3_delta_vs_TITAN = quantile(get(paste0("effect_", other)) - effect_TITAN, 0.75),
    other_higher = sum(get(paste0("effect_", other)) > effect_TITAN),
    TITAN_higher = sum(effect_TITAN > get(paste0("effect_", other))),
    tied = sum(effect_TITAN == get(paste0("effect_", other))),
    spearman_effect = cor(get(paste0("effect_", other)), effect_TITAN,
                          method = "spearman")
  ), by = .(outcome_type, stability_repeat)][,
    comparison := paste(other, "versus TITAN")]
}))
fwrite(pairwise_repeat,
       "results/tables/foundation_model_pairwise_repeat_stability.csv")

consensus_levels <- c("all three", "exactly two", "representation specific", "none")
consensus_stability <- repeat_wide[, {
  counts <- table(factor(consensus_class, levels = consensus_levels))
  max_count <- max(counts)
  modes <- consensus_levels[counts == max_count]
  patterns <- sort(table(support_pattern), decreasing = TRUE)
  list(
    alternative_partitions = .N,
    all_three_proportion = mean(consensus_class == "all three"),
    exactly_two_proportion = mean(consensus_class == "exactly two"),
    representation_specific_proportion = mean(consensus_class == "representation specific"),
    none_proportion = mean(consensus_class == "none"),
    modal_consensus_class = modes[1L],
    modal_consensus_tied = length(modes) > 1L,
    modal_consensus_proportion = max_count / .N,
    modal_support_pattern = names(patterns)[1L],
    modal_support_pattern_proportion = as.numeric(patterns[1L]) / .N,
    mean_supported_by_n = mean(supported_by_n),
    min_supported_by_n = min(supported_by_n),
    max_supported_by_n = max(supported_by_n)
  )
}, by = task_id]
consensus_stability <- merge(
  consensus_stability,
  selection[, c(task_id, "primary_consensus_class", "support_pattern",
                "supported_by_n", "selection_reason", "primary_union_positive",
                "primary_near_threshold", "primary_threshold_distance_min"), with = FALSE],
  by = task_id, all.x = TRUE
)
setnames(consensus_stability, c("support_pattern", "supported_by_n"),
         c("primary_support_pattern", "primary_supported_by_n"))
consensus_stability[, primary_consensus_agreement_proportion := fcase(
  primary_consensus_class == "all three", all_three_proportion,
  primary_consensus_class == "exactly two", exactly_two_proportion,
  primary_consensus_class == "representation specific", representation_specific_proportion,
  default = none_proportion
)]
fwrite(consensus_stability,
       "results/tables/foundation_model_consensus_stability.csv")

effect_rank <- rbindlist(lapply(model_names, function(model) {
  repeat_wide[, .(
    mean_effect = mean(get(paste0("effect_", model))),
    sd_effect = sd(get(paste0("effect_", model))),
    mean_rank_within_outcome_repeat = mean(get(paste0("rank_", model))),
    median_rank_within_outcome_repeat = median(get(paste0("rank_", model))),
    winner_proportion = mean(get(paste0("effect_", model)) ==
                               pmax(effect_TITAN, effect_GigaSSL,
                                    effect_ProvGigaPath))
  ), by = task_id][, foundation_model := model]
}))
fwrite(effect_rank, "results/tables/foundation_model_effect_rank_stability.csv")

threshold_grid <- rbindlist(list(
  data.table(outcome_type = "continuous", threshold = seq(0.10, 0.30, by = 0.01)),
  data.table(outcome_type = "binary", threshold = seq(0.55, 0.65, by = 0.01))
))
threshold_sensitivity <- rbindlist(lapply(seq_len(nrow(threshold_grid)), function(i) {
  type <- threshold_grid$outcome_type[i]
  threshold <- threshold_grid$threshold[i]
  rbindlist(lapply(model_names, function(model) {
    col <- if (type == "continuous") "q2" else "auc"
    repeats[outcome_type == type & foundation_model == model, .(
      selected_tasks = .N,
      crossings = sum(get(col) >= threshold, na.rm = TRUE),
      crossing_proportion = mean(get(col) >= threshold, na.rm = TRUE)
    ), by = stability_repeat][, `:=`(
      outcome_type = type, threshold = threshold, foundation_model = model
    )]
  }))
}))
threshold_sensitivity[, `:=`(
  mean_crossings = mean(crossings),
  min_crossings = min(crossings),
  max_crossings = max(crossings),
  mean_crossing_proportion = mean(crossing_proportion)
), by = .(outcome_type, threshold, foundation_model)]
fwrite(threshold_sensitivity,
       "results/tables/foundation_model_threshold_sensitivity.csv")

threshold_consensus <- rbindlist(lapply(seq_len(nrow(threshold_grid)), function(i) {
  type <- threshold_grid$outcome_type[i]
  threshold <- threshold_grid$threshold[i]
  metric <- if (type == "continuous") "q2" else "auc"
  z <- dcast(repeats[outcome_type == type],
             stability_job_id + stability_repeat ~ foundation_model,
             value.var = metric)
  z[, supported_by_n := rowSums(cbind(TITAN >= threshold,
                                      GigaSSL >= threshold,
                                      ProvGigaPath >= threshold))]
  z[, consensus_class := fcase(
    supported_by_n == 3L, "all three",
    supported_by_n == 2L, "exactly two",
    supported_by_n == 1L, "representation specific",
    default = "none"
  )]
  z[, .N, by = .(stability_repeat, consensus_class)][, `:=`(
    outcome_type = type, threshold = threshold
  )]
}))
threshold_consensus[, selected_tasks := sum(N),
                    by = .(outcome_type, threshold, stability_repeat)]
threshold_consensus[, proportion := N / selected_tasks]
threshold_consensus[, `:=`(
  mean_tasks = mean(N), min_tasks = min(N), max_tasks = max(N),
  mean_proportion = mean(proportion)
), by = .(outcome_type, threshold, consensus_class)]
fwrite(threshold_consensus,
       "results/tables/foundation_model_threshold_consensus_sensitivity.csv")

summary <- crossing_stability[, .(
  selected_tasks = uniqueN(paste(outcome_type, family, tumor_type, endpoint, source)),
  mean_crossing_proportion = mean(crossing_proportion),
  stable_crossing_tasks = sum(crossing_proportion == 1),
  never_crossing_tasks = sum(crossing_proportion == 0),
  variable_crossing_tasks = sum(crossing_proportion > 0 & crossing_proportion < 1),
  median_primary_repeat_agreement = median(primary_repeat_crossing_agreement_proportion)
), by = .(foundation_model, outcome_type)]
fwrite(summary, "results/tables/foundation_model_fold_stability_summary.csv")

display_models <- factor(crossing_stability$foundation_model,
                         levels = model_names,
                         labels = c("TITAN", "Giga-SSL", "Prov-GigaPath"))
plot_crossing <- copy(crossing_stability)
plot_crossing[, display_model := factor(foundation_model, levels = model_names,
                                        labels = c("TITAN", "Giga-SSL", "Prov-GigaPath"))]
p1 <- ggplot(plot_crossing,
             aes(primary_crossing_statistic, crossing_proportion,
                 colour = display_model)) +
  geom_vline(data = data.table(outcome_type = c("continuous", "binary"),
                               threshold = c(continuous_threshold, 0.60)),
             aes(xintercept = threshold), inherit.aes = FALSE,
             linetype = 2, colour = "grey45") +
  geom_point(alpha = 0.30, size = 1.0) +
  facet_wrap(~ outcome_type, scales = "free_x") +
  scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, by = 0.2)) +
  scale_colour_manual(values = c("TITAN" = "#2B6CB0", "Giga-SSL" = "#D97706",
                                 "Prov-GigaPath" = "#17806D")) +
  labs(x = "Primary crossing statistic\n(Q-squared continuous; AUROC binary)",
       y = "Proportion crossing over five alternative partitions",
       colour = NULL, title = "A  Fold-assignment stability") +
  theme_minimal(base_size = 12) + theme(legend.position = "top")

class_summary <- consensus_stability[, .(
  tasks = .N,
  median_primary_class_agreement = median(primary_consensus_agreement_proportion),
  exact_primary_class_in_all_repeats = sum(primary_consensus_agreement_proportion == 1)
), by = .(outcome_type, primary_consensus_class)]
class_summary[, primary_consensus_class := factor(
  primary_consensus_class, levels = consensus_levels
)]
p2 <- ggplot(class_summary,
             aes(primary_consensus_class, median_primary_class_agreement,
                 fill = outcome_type)) +
  geom_col(position = position_dodge(width = 0.75), width = 0.66) +
  geom_text(aes(label = paste0("n=", tasks)),
            position = position_dodge(width = 0.75), vjust = -0.25, size = 3.4) +
  coord_cartesian(ylim = c(0, 1.08)) +
  scale_fill_manual(values = c(binary = "#5B4B8A", continuous = "#2A9D8F")) +
  scale_x_discrete(labels = c(
    "all three" = "all three", "exactly two" = "exactly two",
    "representation specific" = "representation\nspecific", "none" = "none"
  )) +
  labs(x = "Primary consensus class", y = "Median agreement proportion",
       fill = NULL, title = "B  Consensus-class stability") +
  theme_minimal(base_size = 12) + theme(legend.position = "top",
    axis.text.x = element_text(angle = 0, hjust = 0.5))

curve <- unique(threshold_sensitivity[, .(
  outcome_type, threshold, foundation_model, mean_crossing_proportion
)])
curve[, display_model := factor(foundation_model, levels = model_names,
                                labels = c("TITAN", "Giga-SSL", "Prov-GigaPath"))]
p3 <- ggplot(curve, aes(threshold, mean_crossing_proportion,
                        colour = display_model)) +
  geom_line(linewidth = 1.0) + geom_point(size = 1.4) +
  facet_wrap(~ outcome_type, scales = "free_x") +
  scale_colour_manual(values = c("TITAN" = "#2B6CB0", "Giga-SSL" = "#D97706",
                                 "Prov-GigaPath" = "#17806D")) +
  labs(x = "Effect threshold", y = "Mean crossing proportion",
       colour = NULL, title = "C  Threshold-sensitivity curves") +
  theme_minimal(base_size = 12) + theme(legend.position = "top")

dir.create("results/figures", recursive = TRUE, showWarnings = FALSE)
dir.create("figures", recursive = TRUE, showWarnings = FALSE)
combined <- p1 / (p2 | p3) + plot_layout(heights = c(1.05, 0.95))
ggsave("results/figures/FigureS6_foundation_model_fold_threshold_stability.png",
       combined, width = 13.5, height = 10.0, dpi = 320, bg = "white")
ggsave("figures/FigureS6_foundation_model_fold_threshold_stability.png",
       combined, width = 13.5, height = 10.0, dpi = 320, bg = "white")

print(summary)
print(class_summary)
