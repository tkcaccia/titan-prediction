.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
backend <- tolower(Sys.getenv("TITAN_BACKEND", "cpu"))
options(fastPLS.backend = backend)
cohort <- readRDS("data/processed/patient_cohort.rds")
targets <- readRDS("data/processed/continuous_targets.rds")
catalog <- fread("results/tables/continuous_target_catalog.csv")
jobs <- catalog[n >= cfg$analysis$continuous_min_n & is.finite(sd) & sd > 0]
jobs[, job_id := .I]

checkpoint_dir <- "data/processed/checkpoints/continuous"
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)
workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
future::plan(future::multicore, workers = workers)

fastpls_description <- packageDescription("fastPLS")
analysis_fingerprint <- digest::digest(list(
  checkpoint_schema = 2L,
  script_sha256 = digest::digest(file = "R/04_screen_continuous.R", algo = "sha256"),
  utils_sha256 = digest::digest(file = "R/utils.R", algo = "sha256"),
  cohort_sha256 = digest::digest(
    file = "data/processed/patient_cohort.rds", algo = "sha256"
  ),
  targets_sha256 = digest::digest(
    file = "data/processed/continuous_targets.rds", algo = "sha256"
  ),
  catalog_sha256 = digest::digest(
    file = "results/tables/continuous_target_catalog.csv", algo = "sha256"
  ),
  analysis = cfg$analysis,
  fastPLS_version = as.character(packageVersion("fastPLS")),
  fastPLS_remote_sha = as.character(fastpls_description$RemoteSha),
  backend = backend
), algo = "sha256")

checkpoint_is_current <- function(path, model_id) {
  if (!file.exists(path)) return(FALSE)
  object <- tryCatch(readRDS(path), error = function(e) NULL)
  if (is.null(object) ||
      !identical(object$analysis_fingerprint, analysis_fingerprint) ||
      is.null(object$row) || nrow(object$row) != 1L) return(FALSE)
  identical(
    safe_name(object$row$family, object$row$tumor_type, object$row$endpoint),
    model_id
  )
}

run_job <- function(i) {
  job <- jobs[i]
  model_id <- safe_name(job$family, job$tumor_type, job$endpoint)
  checkpoint <- file.path(
    checkpoint_dir,
    paste0(model_id, ".rds")
  )
  if (checkpoint_is_current(checkpoint, model_id)) return(NULL)
  d <- targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx) & is.finite(d$value)
  X <- cohort$X[idx[keep], , drop = FALSE]
  y <- d$value[keep]
  seed <- cfg$analysis$seed + i
  fit <- pls.double.cv(
    X, y, ncomp = cfg$analysis$components,
    svd.method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    kfold_outer = cfg$analysis$outer_folds,
    kfold_inner = cfg$analysis$inner_folds,
    seed = seed, perm.test = FALSE
  )
  q2 <- as.numeric(fit$Q2Y)
  # Performance is checkpointed for the complete atlas first. Only models able
  # to meet the prespecified screening threshold receive 99/999 permutations in R/05b.
  p <- 1; nperm <- 0L; exceed <- NA_integer_
  row <- data.table(
    family = job$family, subfamily = job$subfamily,
    tumor_type = job$tumor_type, endpoint = job$endpoint,
    source = job$source, n = length(y), q2 = q2,
    rmse = sqrt(mean((y - as.numeric(fit$Ypred))^2)),
    spearman = suppressWarnings(cor(y, as.numeric(fit$Ypred), method = "spearman")),
    p_permutation = p, permutations = nperm,
    permutation_exceedances = exceed,
    ncomp = as.integer(fit$bcomp), seed = seed,
    fastPLS_version = as.character(packageVersion("fastPLS")),
    backend = backend, svd_method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power
  )
  saveRDS(list(
    analysis_fingerprint = analysis_fingerprint,
    row = row,
    predictions = data.table(patient = d$patient[keep], observed = y,
                             predicted = as.numeric(fit$Ypred))
  ), checkpoint)
  NULL
}

invisible(future_lapply(
  seq_len(nrow(jobs)), run_job, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table"),
  future.globals = TRUE, future.chunk.size = 1
))

expected_ids <- vapply(seq_len(nrow(jobs)), function(i) {
  safe_name(jobs$family[i], jobs$tumor_type[i], jobs$endpoint[i])
}, character(1))
if (anyDuplicated(expected_ids)) stop("Continuous jobs produced duplicate checkpoint IDs")
expected_checkpoints <- file.path(checkpoint_dir, paste0(expected_ids, ".rds"))
if (!all(file.exists(expected_checkpoints))) stop("A continuous checkpoint is missing")
objects <- lapply(expected_checkpoints, readRDS)
if (!all(vapply(objects, function(z) {
  identical(z$analysis_fingerprint, analysis_fingerprint)
}, logical(1)))) stop("A continuous checkpoint has a stale analysis fingerprint")
results <- rbindlist(lapply(objects, `[[`, "row"), fill = TRUE)
results[, q_value := p.adjust(p_permutation, method = "BH"), by = family]
results[, tier := fifelse(
  q_value < cfg$analysis$fdr_alpha & q2 >= 0.40, "A",
  fifelse(q_value < cfg$analysis$fdr_alpha & q2 >= 0.20, "B", "C")
)]
setorder(results, family, -q2)
fwrite(results, "results/tables/continuous_screen.csv")
saveRDS(lapply(objects, `[[`, "predictions"),
        "results/predictions/continuous_oof_predictions.rds", compress = "xz")
print(results[, .N, by = .(family, tier)])
