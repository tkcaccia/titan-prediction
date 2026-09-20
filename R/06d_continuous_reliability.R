.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")

cfg <- load_project_config()
options(backend = tolower(Sys.getenv("TITAN_BACKEND", "cpu")))
cohort <- readRDS("data/processed/patient_cohort.rds")
targets <- readRDS("data/processed/continuous_targets.rds")
jobs <- fread("results/tables/continuous_screen.csv")[tier %in% c("A", "B")]
repeated <- fread("results/tables/continuous_repeated_nested_cv.csv")
predictions <- fread("results/predictions/continuous_repeated_oof_predictions.csv.gz")

checkpoint_dir <- "data/processed/checkpoints/continuous_reliability"
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)

audit_one <- function(i) {
  job <- jobs[i]
  id <- safe_name(job$family, job$tumor_type, job$endpoint)
  checkpoint <- file.path(checkpoint_dir, paste0(id, ".rds"))
  if (file.exists(checkpoint)) return(readRDS(checkpoint))
  d <- targets[family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx) & is.finite(d$value)
  X <- cohort$X[idx[keep], , drop = FALSE]
  y <- d$value[keep]
  rows <- rbindlist(lapply(seq_len(cfg$analysis$robustness_repeats), function(r) {
    seed <- cfg$analysis$seed + 10000L * r + i
    fit <- fit_continuous_nested_once(X, y, cfg$analysis, seed)
    data.table(
      family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint,
      n = length(y), `repeat` = r, outer_fold = seq_along(fit$ncomp),
      selected_components = as.integer(fit$ncomp),
      reached_ceiling = fit$ncomp == max(cfg$analysis$components), seed = seed
    )
  }))
  saveRDS(rows, checkpoint)
  rows
}

workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
future::plan(future::multicore, workers = workers)
component_rows <- rbindlist(future_lapply(
  seq_len(nrow(jobs)), audit_one, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table"), future.globals = TRUE,
  future.chunk.size = 1
))
setorderv(component_rows, c("family", "tumor_type", "endpoint", "repeat", "outer_fold"))
fwrite(component_rows, "results/tables/continuous_selected_components_by_fold.csv")

key <- c("family", "tumor_type", "endpoint")
sample_sizes <- unique(component_rows[, c(key, "n"), with = FALSE])
sample_sizes[, evidence_category := fifelse(
  n < 100L, "limited continuous evidence (<100 patients)",
  "standard continuous internal evidence (>=100 patients)"
)]

repeat_summary <- repeated[, .(
  repeated_q2_mean = mean(q2), repeated_q2_sd = sd(q2),
  repeated_q2_min = min(q2), repeated_q2_max = max(q2),
  repeated_spearman_mean = mean(spearman), repeated_spearman_sd = sd(spearman)
), by = key]

stability <- predictions[, {
  z <- copy(.SD)
  setnames(z, "repeat", "rep_id")
  wide <- dcast(z, patient ~ rep_id, value.var = "predicted")
  mat <- as.matrix(wide[, -"patient"])
  correlations <- cor(mat, method = "spearman", use = "pairwise.complete.obs")
  values <- correlations[upper.tri(correlations)]
  .(prediction_repeat_spearman_mean = mean(values),
    prediction_repeat_spearman_min = min(values),
    prediction_repeat_spearman_sd = sd(values))
}, by = key]

components <- component_rows[, .(
  selected_components_median = median(selected_components),
  selected_components_min = min(selected_components),
  selected_components_max = max(selected_components),
  selected_components_iqr = IQR(selected_components),
  outer_fits = .N, outer_fits_at_ceiling = sum(reached_ceiling),
  outer_fit_ceiling_fraction = mean(reached_ceiling),
  any_outer_fit_at_ceiling = any(reached_ceiling)
), by = key]

model_summary <- Reduce(function(x, y) merge(x, y, by = key, all = TRUE),
                        list(sample_sizes, repeat_summary, stability, components))
setorder(model_summary, n, family, tumor_type, endpoint)
fwrite(model_summary, "results/tables/continuous_reliability_by_model.csv")

breaks <- c(49, 74, 99, 199, 399, Inf)
labels <- c("50-74", "75-99", "100-199", "200-399", ">=400")
model_summary[, sample_size_band := cut(n, breaks = breaks, labels = labels)]
model_summary[, sample_size_band := as.character(sample_size_band)]
band_summary <- model_summary[, .(
  models = .N, n_min = as.numeric(min(n)), n_median = as.numeric(median(n)), n_max = as.numeric(max(n)),
  q2_median = median(repeated_q2_mean), q2_iqr_low = quantile(repeated_q2_mean, .25),
  q2_iqr_high = quantile(repeated_q2_mean, .75),
  q2_repeat_sd_median = median(repeated_q2_sd),
  prediction_repeat_spearman_median = median(prediction_repeat_spearman_mean),
  prediction_repeat_spearman_iqr_low = quantile(prediction_repeat_spearman_mean, .25),
  prediction_repeat_spearman_iqr_high = quantile(prediction_repeat_spearman_mean, .75),
  selected_components_median = as.numeric(median(selected_components_median)),
  outer_fits_at_ceiling = as.numeric(sum(outer_fits_at_ceiling)), outer_fits = as.numeric(sum(outer_fits)),
  outer_fit_ceiling_percent = 100 * sum(outer_fits_at_ceiling) / sum(outer_fits),
  models_with_any_ceiling = as.numeric(sum(any_outer_fit_at_ceiling))
), by = sample_size_band]
fwrite(band_summary, "results/tables/continuous_reliability_by_sample_size.csv")

evidence_summary <- model_summary[, .(
  models = .N, n_min = as.numeric(min(n)), n_median = as.numeric(median(n)), n_max = as.numeric(max(n)),
  q2_median = median(repeated_q2_mean), q2_repeat_sd_median = median(repeated_q2_sd),
  prediction_repeat_spearman_median = median(prediction_repeat_spearman_mean),
  selected_components_median = as.numeric(median(selected_components_median)),
  outer_fits_at_ceiling = as.numeric(sum(outer_fits_at_ceiling)), outer_fits = as.numeric(sum(outer_fits)),
  outer_fit_ceiling_percent = 100 * sum(outer_fits_at_ceiling) / sum(outer_fits),
  models_with_any_ceiling = as.numeric(sum(any_outer_fit_at_ceiling))
), by = evidence_category]
fwrite(evidence_summary, "results/tables/continuous_evidence_category_summary.csv")

association_summary <- data.table(
  metric = c("five-repeat mean Q2", "mean pairwise repeat-prediction Spearman correlation"),
  sample_size_spearman = c(
    cor(model_summary$n, model_summary$repeated_q2_mean, method = "spearman"),
    cor(model_summary$n, model_summary$prediction_repeat_spearman_mean, method = "spearman")
  ),
  interpretation = c(
    "descriptive association; not a causal sample-size effect",
    "descriptive association; larger samples tended to have more stable predictions"
  )
)
fwrite(association_summary, "results/tables/continuous_reliability_association_summary.csv")

limited <- model_summary[n < 100L]
limited[, default_inference := FALSE]
limited[, warning := paste(
  "Limited continuous evidence: fewer than 100 TCGA patients; internally",
  "validated only. Inspect repeat stability and component-selection metadata."
)]
fwrite(limited, "results/tables/continuous_limited_evidence_models.csv")

cat("continuous reliability audit:", nrow(model_summary), "models;",
    nrow(limited), "limited;", sum(component_rows$reached_ceiling), "/",
    nrow(component_rows), "outer fits at ceiling\n")
