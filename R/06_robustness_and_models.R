.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
cohort <- readRDS("data/processed/patient_cohort.rds")
continuous_targets <- readRDS("data/processed/continuous_targets.rds")
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)
continuous_jobs <- fread("results/tables/continuous_screen.csv")[tier %in% c("A", "B")]
binary_jobs <- fread("results/tables/binary_screen.csv")[tier %in% c("A", "B")]
dir.create("models", showWarnings = FALSE)
checkpoint_dir <- "data/processed/checkpoints/robustness_models"
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)

run_continuous <- function(i) {
  job <- continuous_jobs[i]
  model_id <- safe_name(job$family, job$tumor_type, job$endpoint)
  checkpoint <- file.path(checkpoint_dir, paste0(model_id, ".rds"))
  if (file.exists(checkpoint)) return(NULL)
  d <- continuous_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx) & is.finite(d$value)
  X <- cohort$X[idx[keep], , drop = FALSE]
  y <- d$value[keep]
  reps <- lapply(seq_len(cfg$analysis$robustness_repeats), function(r) {
    fit_continuous_nested_once(
      X, y, cfg$analysis, cfg$analysis$seed + 10000L * r + i
    )
  })
  repeat_rows <- rbindlist(lapply(seq_along(reps), function(r) data.table(
    family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint,
    `repeat` = r, q2 = reps[[r]]$q2, rmse = reps[[r]]$rmse,
    spearman = reps[[r]]$correlation
  )))
  tune <- pls.single.cv(
    X, y, ncomp = cfg$analysis$components, kfold = 10,
    seed = cfg$analysis$seed + i, fit = FALSE
  )
  model <- fit_final_model(
    X, y, "continuous", tune$best_ncomp, cfg$analysis, cfg$analysis$seed + i
  )
  artifact <- list(
    model = model, model_id = model_id, outcome_type = "continuous",
    family = job$family, cancer_type = job$tumor_type, endpoint = job$endpoint,
    feature_names = cohort$feature_names, aggregation = cohort$aggregation,
    ncomp = tune$best_ncomp, training_n = length(y),
    fastPLS_version = as.character(packageVersion("fastPLS")),
    intended_use = "Research use only; internally validated TCGA model"
  )
  model_file <- file.path("models", paste0(model_id, ".rds"))
  saveRDS(artifact, model_file, compress = "xz")
  registry <- data.table(
    model_id, family = job$family, cancer_type = job$tumor_type,
    endpoint = job$endpoint, outcome_type = "continuous", n = length(y),
    positive = NA_integer_, negative = NA_integer_, ncomp = tune$best_ncomp,
    tier = job$tier, file = model_file,
    sha256 = digest::digest(file = model_file, algo = "sha256")
  )
  saveRDS(list(repeats = repeat_rows, registry = registry), checkpoint)
  NULL
}

run_binary <- function(i) {
  job <- binary_jobs[i]
  model_id <- safe_name(job$family, job$tumor_type, job$endpoint)
  checkpoint <- file.path(checkpoint_dir, paste0(model_id, ".rds"))
  if (file.exists(checkpoint)) return(NULL)
  d <- binary_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx) & d$value %in% c(0L, 1L)
  X <- cohort$X[idx[keep], , drop = FALSE]
  y <- factor(d$value[keep], levels = c(0L, 1L))
  reps <- lapply(seq_len(cfg$analysis$robustness_repeats), function(r) {
    fit_binary_nested_once(
      X, y, cfg$analysis, cfg$analysis$seed + 10000L * r + i
    )
  })
  repeat_rows <- rbindlist(lapply(seq_along(reps), function(r) data.table(
    family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint,
    `repeat` = r, balanced_accuracy = reps[[r]]$balanced_accuracy,
    auc = reps[[r]]$auc
  )))
  tune <- pls.single.cv(
    X, y, ncomp = cfg$analysis$components, kfold = 10,
    seed = cfg$analysis$seed + i, classifier = "lda",
    lda_ridge = cfg$analysis$lda_ridge,
    selection_metric = "balanced_accuracy", fit = FALSE
  )
  model <- fit_final_model(
    X, y, "binary", tune$best_ncomp, cfg$analysis, cfg$analysis$seed + i
  )
  artifact <- list(
    model = model, model_id = model_id, outcome_type = "binary",
    family = job$family, cancer_type = job$tumor_type, endpoint = job$endpoint,
    feature_names = cohort$feature_names, aggregation = cohort$aggregation,
    ncomp = tune$best_ncomp, training_n = length(y),
    positive = sum(y == "1"), negative = sum(y == "0"),
    fastPLS_version = as.character(packageVersion("fastPLS")),
    intended_use = "Research use only; internally validated TCGA model"
  )
  model_file <- file.path("models", paste0(model_id, ".rds"))
  saveRDS(artifact, model_file, compress = "xz")
  registry <- data.table(
    model_id, family = job$family, cancer_type = job$tumor_type,
    endpoint = job$endpoint, outcome_type = "binary", n = length(y),
    positive = sum(y == "1"), negative = sum(y == "0"),
    ncomp = tune$best_ncomp, tier = job$tier, file = model_file,
    sha256 = digest::digest(file = model_file, algo = "sha256")
  )
  saveRDS(list(repeats = repeat_rows, registry = registry), checkpoint)
  NULL
}

workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
future::plan(future::multicore, workers = workers)
invisible(future_lapply(
  seq_len(nrow(continuous_jobs)), run_continuous, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table", "digest"),
  future.globals = TRUE, future.chunk.size = 1
))
invisible(future_lapply(
  seq_len(nrow(binary_jobs)), run_binary, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table", "digest"),
  future.globals = TRUE, future.chunk.size = 1
))

objects <- lapply(list.files(checkpoint_dir, pattern = "[.]rds$", full.names = TRUE), readRDS)
continuous_repeats <- rbindlist(lapply(objects, function(z) {
  if (z$registry$outcome_type == "continuous") z$repeats else NULL
}), fill = TRUE)
binary_repeats <- rbindlist(lapply(objects, function(z) {
  if (z$registry$outcome_type == "binary") z$repeats else NULL
}), fill = TRUE)
registry <- rbindlist(lapply(objects, `[[`, "registry"), fill = TRUE)
setorder(registry, family, cancer_type, endpoint)
fwrite(continuous_repeats, "results/tables/continuous_repeated_nested_cv.csv")
fwrite(binary_repeats, "results/tables/binary_repeated_nested_cv.csv")
fwrite(registry, "models/model_registry.csv")
cat("saved research models:", nrow(registry), "\n")
