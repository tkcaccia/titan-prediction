.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
backend <- tolower(Sys.getenv("TITAN_BACKEND", "cpu"))
options(backend = backend)
fastpls_description <- packageDescription("fastPLS")
fastpls_version <- as.character(packageVersion("fastPLS"))
fastpls_remote_sha <- as.character(fastpls_description$RemoteSha)
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

# A filename alone is not sufficient evidence that a cached robustness/model
# result belongs to the current release. Bind every reusable checkpoint to the
# finalized screens, analysis configuration, cohort schema/source, software
# build and backend. Old checkpoints remain on disk but are neither reused nor
# collated unless this fingerprint matches.
analysis_fingerprint <- digest::digest(list(
  checkpoint_schema = 2L,
  numerical_specification = "patient-level-repeated-nested-cv-rsvd-v3",
  utils_sha256 = digest::digest(file = "R/utils.R", algo = "sha256"),
  cohort_sha256 = digest::digest(
    file = "data/processed/patient_cohort.rds", algo = "sha256"
  ),
  continuous_targets_sha256 = digest::digest(
    file = "data/processed/continuous_targets.rds", algo = "sha256"
  ),
  binary_nonmutation_targets_sha256 = digest::digest(
    file = "data/processed/binary_targets_nonmutation.rds", algo = "sha256"
  ),
  binary_mutation_targets_sha256 = digest::digest(
    file = "data/processed/binary_targets_mutation.rds", algo = "sha256"
  ),
  continuous_screen_sha256 = digest::digest(
    file = "results/tables/continuous_screen.csv", algo = "sha256"
  ),
  binary_screen_sha256 = digest::digest(
    file = "results/tables/binary_screen.csv", algo = "sha256"
  ),
  analysis = cfg$analysis,
  feature_names = cohort$feature_names,
  cohort_source_sha256 = cohort$source_sha256,
  patient_ids = rownames(cohort$X),
  fastPLS_version = fastpls_version,
  fastPLS_remote_sha = fastpls_remote_sha,
  backend = backend
), algo = "sha256")

# The preceding access-controlled release used this exact fingerprint. Its
# repeated and final fits already record the current fastPLS Git SHA and the
# same cohort/target/configuration inputs. The present source change adds binary
# decision-rule metadata plus removal of unregistered artifacts; it does not
# alter numerical fitting. Candidate membership, sample/class counts and tiers
# are checked before any legacy checkpoint can be re-indexed.
compatible_legacy_fingerprints <- c(
  "65f5c4e5df41fb32a17d8fd99cd10e48813ea1d132a91804326a8872230e35bd",
  "33c1993fe49fc8c0b271de0df1ca433354c34662a3c9b8e416bfcc0b4e99e369"
)

atomic_save_rds <- function(object, path) {
  temporary <- paste0(path, ".tmp-", Sys.getpid())
  saveRDS(object, temporary, compress = "xz")
  if (!file.rename(temporary, path)) {
    unlink(temporary)
    stop("Could not atomically replace checkpoint/artifact: ", path)
  }
  invisible(path)
}

compatible_job <- function(registry, outcome_type) {
  jobs <- if (outcome_type == "continuous") continuous_jobs else binary_jobs
  job <- jobs[
    family == registry$family & tumor_type == registry$cancer_type &
      endpoint == registry$endpoint
  ]
  if (nrow(job) != 1L || as.integer(job$n) != as.integer(registry$n) ||
      !identical(as.character(job$tier), as.character(registry$tier))) {
    return(FALSE)
  }
  if (outcome_type == "binary" && (
    as.integer(job$positive) != as.integer(registry$positive) ||
      as.integer(job$negative) != as.integer(registry$negative)
  )) return(FALSE)
  TRUE
}

migrate_compatible_checkpoint <- function(object, path, model_id, outcome_type) {
  if (!isTRUE(object$analysis_fingerprint %in% compatible_legacy_fingerprints) ||
      is.null(object$registry) || nrow(object$registry) != 1L ||
      !identical(as.character(object$registry$model_id), model_id) ||
      !identical(as.character(object$registry$outcome_type), outcome_type) ||
      !compatible_job(object$registry, outcome_type) ||
      nrow(object$repeats) != cfg$analysis$robustness_repeats ||
      !nrow(object$predictions)) return(FALSE)
  model_file <- as.character(object$registry$file)
  if (!file.exists(model_file) ||
      !identical(digest::digest(file = model_file, algo = "sha256"),
                 as.character(object$registry$sha256))) return(FALSE)
  artifact <- tryCatch(readRDS(model_file), error = function(e) NULL)
  if (is.null(artifact) ||
      !identical(as.character(artifact$model_id), model_id) ||
      !identical(as.character(artifact$outcome_type), outcome_type) ||
      !identical(as.character(artifact$fastPLS_version), fastpls_version) ||
      !identical(as.character(artifact$fastPLS_remote_sha), fastpls_remote_sha) ||
      !identical(as.character(artifact$backend), backend) ||
      !identical(as.character(artifact$svd_method), cfg$analysis$svd_method) ||
      as.integer(artifact$rsvd_oversample) != cfg$analysis$rsvd_oversample ||
      as.integer(artifact$rsvd_power) != cfg$analysis$rsvd_power ||
      !identical(as.character(artifact$titan_feature_file_sha256),
                 as.character(cohort$source_sha256)) ||
      !identical(as.character(artifact$feature_schema_sha256),
                 digest::digest(cohort$feature_names, algo = "sha256")) ||
      !isTRUE(artifact$analysis_fingerprint %in%
                c(compatible_legacy_fingerprints, object$analysis_fingerprint))) {
    return(FALSE)
  }
  if (outcome_type == "binary") {
    rule <- paste(
      "empirical outer-training-fold LDA priors in internal validation;",
      "fitted full-cohort priors for inference"
    )
    artifact$primary_binary_decision_rule <- rule
    artifact$deployment_metadata$primary_binary_decision_rule <- rule
    object$registry[, primary_binary_decision_rule := rule]
  }
  source_fingerprint <- as.character(object$analysis_fingerprint)
  artifact$analysis_fingerprint <- analysis_fingerprint
  atomic_save_rds(artifact, model_file)
  registry_row <- data.table::as.data.table(data.table::copy(object$registry))
  registry_row$sha256 <- digest::digest(file = model_file, algo = "sha256")
  registry_row$analysis_fingerprint <- analysis_fingerprint
  object$registry <- registry_row
  object$analysis_fingerprint <- analysis_fingerprint
  object$provenance_reuse_audit <- data.table(
    model_id = model_id,
    outcome_type = outcome_type,
    source_fingerprint = source_fingerprint,
    release_fingerprint = analysis_fingerprint,
    numerical_refit_performed = FALSE,
    reuse_basis = paste(
      "candidate membership, sample/class counts, tier, artifact hash,",
      "cohort/schema hashes, exact fastPLS Git SHA, backend and rSVD settings matched;",
      "source change was metadata/cleanup only"
    )
  )
  atomic_save_rds(object, path)
  TRUE
}

checkpoint_is_current <- function(path, model_id, outcome_type) {
  if (!file.exists(path)) return(FALSE)
  object <- tryCatch(readRDS(path), error = function(e) NULL)
  if (!is.null(object) &&
      !identical(object$analysis_fingerprint, analysis_fingerprint) &&
      migrate_compatible_checkpoint(object, path, model_id, outcome_type)) {
    return(TRUE)
  }
  object <- tryCatch(readRDS(path), error = function(e) NULL)
  if (!is.null(object) &&
      identical(object$analysis_fingerprint, analysis_fingerprint) &&
      is.data.frame(object$registry) && nrow(object$registry) == 1L &&
      !identical(as.character(object$registry$analysis_fingerprint),
                 analysis_fingerprint)) {
    model_file <- as.character(object$registry$file)
    artifact <- if (file.exists(model_file))
      tryCatch(readRDS(model_file), error = function(e) NULL) else NULL
    if (!is.null(artifact) &&
        identical(as.character(artifact$analysis_fingerprint),
                  analysis_fingerprint) &&
        identical(digest::digest(file = model_file, algo = "sha256"),
                  as.character(object$registry$sha256))) {
      registry_row <- data.table::as.data.table(
        data.table::copy(object$registry)
      )
      registry_row$analysis_fingerprint <- analysis_fingerprint
      object$registry <- registry_row
      atomic_save_rds(object, path)
    }
  }
  if (is.null(object) ||
      !identical(object$analysis_fingerprint, analysis_fingerprint) ||
      is.null(object$registry) || nrow(object$registry) != 1L ||
      !identical(as.character(object$registry$model_id), model_id) ||
      !identical(as.character(object$registry$outcome_type), outcome_type)) {
    return(FALSE)
  }
  model_file <- as.character(object$registry$file)
  file.exists(model_file) &&
    identical(digest::digest(file = model_file, algo = "sha256"),
              as.character(object$registry$sha256))
}

run_continuous <- function(i) {
  job <- continuous_jobs[i]
  model_id <- safe_name(job$family, job$tumor_type, job$endpoint)
  checkpoint <- file.path(checkpoint_dir, paste0(model_id, ".rds"))
  if (checkpoint_is_current(checkpoint, model_id, "continuous")) return(NULL)
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
  prediction_rows <- rbindlist(lapply(seq_along(reps), function(r) data.table(
    family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint,
    `repeat` = r, patient = d$patient[keep], observed = y,
    predicted = reps[[r]]$prediction, outer_fold = reps[[r]]$fold
  )))
  tune <- pls.single.cv(
    X, y, ncomp = cfg$analysis$components, kfold = 10,
    seed = cfg$analysis$seed + i, rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power, fit = FALSE
  )
  model <- fit_final_model(
    X, y, "continuous", tune$best_ncomp, cfg$analysis, cfg$analysis$seed + i
  )
  fit_seed <- cfg$analysis$seed + i
  # fastPLS retains training latent scores and fitted values for diagnostics.
  # They are not required by predict() and are removed from deployable objects
  # so the artifact contains no patient-level training rows.
  model$Ttrain <- NULL
  model$Yfit <- NULL
  endpoint_transform <- continuous_endpoint_transform(job$family, job$endpoint)
  output_units <- if (endpoint_transform == "log1p") {
    "log1p-transformed source endpoint units"
  } else {
    "source endpoint units"
  }
  artifact <- list(
    model = model, model_id = model_id, outcome_type = "continuous",
    family = job$family, cancer_type = job$tumor_type, endpoint = job$endpoint,
    feature_names = cohort$feature_names, aggregation = cohort$aggregation,
    ncomp = tune$best_ncomp, training_n = length(y),
    endpoint_transform = endpoint_transform,
    output_units = output_units,
    training_feature_min = apply(X, 2L, min),
    training_feature_max = apply(X, 2L, max),
    training_feature_mean = colMeans(X),
    training_feature_sd = apply(X, 2L, sd),
    titan_feature_file_sha256 = cohort$source_sha256,
    feature_schema_sha256 = digest::digest(cohort$feature_names, algo = "sha256"),
    deployment_metadata = list(
      training_cohort = "TCGA primary-tumour diagnostic slides",
      input_level = "one or more 768-dimensional TITAN slide embeddings per patient",
      slide_aggregation = cohort$aggregation,
      external_validation = "none",
      calibration_status = "not evaluated",
      contains_patient_level_training_rows = FALSE,
      intended_population = job$tumor_type,
      endpoint_transform = endpoint_transform,
      output_units = output_units,
      fastPLS_version = fastpls_version,
      fastPLS_remote_sha = fastpls_remote_sha,
      backend = backend,
      svd_method = cfg$analysis$svd_method,
      rsvd_oversample = cfg$analysis$rsvd_oversample,
      rsvd_power = cfg$analysis$rsvd_power,
      fit_seed = fit_seed
    ),
    fastPLS_version = fastpls_version,
    fastPLS_remote_sha = fastpls_remote_sha,
    backend = backend,
    svd_method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    fit_seed = fit_seed,
    analysis_fingerprint = analysis_fingerprint,
    intended_use = "Research use only; TCGA discovery model without external validation"
  )
  model_file <- file.path("models", paste0(model_id, ".rds"))
  saveRDS(artifact, model_file, compress = "xz")
  registry <- data.table(
    model_id, family = job$family, cancer_type = job$tumor_type,
    endpoint = job$endpoint, outcome_type = "continuous", n = length(y),
    positive = NA_integer_, negative = NA_integer_, ncomp = tune$best_ncomp,
    tier = job$tier, file = model_file,
    sha256 = digest::digest(file = model_file, algo = "sha256"),
    training_cohort = "TCGA", aggregation = cohort$aggregation,
    feature_dimension = ncol(X), external_validation = "none",
    titan_feature_file_sha256 = cohort$source_sha256,
    feature_schema_sha256 = digest::digest(cohort$feature_names, algo = "sha256"),
    prediction_rule = paste("PLS regression in", output_units),
    endpoint_transform = endpoint_transform, output_units = output_units,
    class_labels = NA_character_, class_priors = NA_character_,
    calibration_status = "not evaluated",
    fastPLS_version = fastpls_version,
    fastPLS_remote_sha = fastpls_remote_sha, backend = backend,
    svd_method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    fit_seed = fit_seed,
    analysis_fingerprint = analysis_fingerprint,
    contains_patient_level_training_rows = FALSE,
    intended_use = "Research use only; TCGA discovery model without external validation",
    redistribution_status = paste(
      "private TITAN-derived artifact; non-commercial academic research only;",
      "public redistribution prohibited unless the TITAN rights holder grants permission"
    )
  )
  saveRDS(list(analysis_fingerprint = analysis_fingerprint,
               repeats = repeat_rows, predictions = prediction_rows,
               registry = registry), checkpoint)
  NULL
}

run_binary <- function(i) {
  job <- binary_jobs[i]
  model_id <- safe_name(job$family, job$tumor_type, job$endpoint)
  checkpoint <- file.path(checkpoint_dir, paste0(model_id, ".rds"))
  if (checkpoint_is_current(checkpoint, model_id, "binary")) return(NULL)
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
  repeat_rows <- rbindlist(lapply(seq_along(reps), function(r) {
    metrics <- binary_classification_metrics(
      y, reps[[r]]$prediction, reps[[r]]$score
    )
    data.table(
      family = job$family, tumor_type = job$tumor_type,
      endpoint = job$endpoint, `repeat` = r,
      sensitivity = metrics$sensitivity,
      specificity = metrics$specificity,
      balanced_accuracy = metrics$balanced_accuracy,
      auc = metrics$auc
    )
  }))
  prediction_rows <- rbindlist(lapply(seq_along(reps), function(r) data.table(
    family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint,
    `repeat` = r, patient = d$patient[keep], observed = as.integer(as.character(y)),
    predicted = as.integer(as.character(reps[[r]]$prediction)),
    lda_score = reps[[r]]$score, outer_fold = reps[[r]]$fold
  )))
  tune <- pls.single.cv(
    X, y, ncomp = cfg$analysis$components, kfold = 10,
    seed = cfg$analysis$seed + i, classifier = "lda", selection = "balanced_accuracy", rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power, fit = FALSE
  )
  model <- fit_final_model(
    X, y, "binary", tune$best_ncomp, cfg$analysis, cfg$analysis$seed + i
  )
  fit_seed <- cfg$analysis$seed + i
  model$Ttrain <- NULL
  model$Yfit <- NULL
  artifact <- list(
    model = model, model_id = model_id, outcome_type = "binary",
    family = job$family, cancer_type = job$tumor_type, endpoint = job$endpoint,
    feature_names = cohort$feature_names, aggregation = cohort$aggregation,
    ncomp = tune$best_ncomp, training_n = length(y),
    endpoint_transform = "none",
    output_units = "class label and uncalibrated LDA score",
    positive = sum(y == "1"), negative = sum(y == "0"),
    class_labels = c(wild_type_or_negative = "0", altered_or_positive = "1"),
    class_priors = prop.table(table(y)),
    decision_rule = paste(
      "class returned by the fitted ridge-stabilised LDA on PLS scores;",
      "lda_score > 0 favours class 1"
    ),
    primary_binary_decision_rule =
      "empirical outer-training-fold LDA priors in internal validation; fitted full-cohort priors for inference",
    training_feature_min = apply(X, 2L, min),
    training_feature_max = apply(X, 2L, max),
    training_feature_mean = colMeans(X),
    training_feature_sd = apply(X, 2L, sd),
    titan_feature_file_sha256 = cohort$source_sha256,
    feature_schema_sha256 = digest::digest(cohort$feature_names, algo = "sha256"),
    deployment_metadata = list(
      training_cohort = "TCGA primary-tumour diagnostic slides",
      input_level = "one or more 768-dimensional TITAN slide embeddings per patient",
      slide_aggregation = cohort$aggregation,
      external_validation = "none",
      calibration_status = "not evaluated; LDA score is not a calibrated probability",
      contains_patient_level_training_rows = FALSE,
      intended_population = job$tumor_type,
      positive_class = "1",
      primary_binary_decision_rule =
        "empirical outer-training-fold LDA priors in internal validation; fitted full-cohort priors for inference",
      endpoint_transform = "none",
      output_units = "class label and uncalibrated LDA score",
      fastPLS_version = fastpls_version,
      fastPLS_remote_sha = fastpls_remote_sha,
      backend = backend,
      svd_method = cfg$analysis$svd_method,
      rsvd_oversample = cfg$analysis$rsvd_oversample,
      rsvd_power = cfg$analysis$rsvd_power,
      fit_seed = fit_seed
    ),
    fastPLS_version = fastpls_version,
    fastPLS_remote_sha = fastpls_remote_sha,
    backend = backend,
    svd_method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    fit_seed = fit_seed,
    analysis_fingerprint = analysis_fingerprint,
    intended_use = "Research use only; TCGA discovery model without external validation"
  )
  model_file <- file.path("models", paste0(model_id, ".rds"))
  saveRDS(artifact, model_file, compress = "xz")
  registry <- data.table(
    model_id, family = job$family, cancer_type = job$tumor_type,
    endpoint = job$endpoint, outcome_type = "binary", n = length(y),
    positive = sum(y == "1"), negative = sum(y == "0"),
    ncomp = tune$best_ncomp, tier = job$tier, file = model_file,
    sha256 = digest::digest(file = model_file, algo = "sha256"),
    training_cohort = "TCGA", aggregation = cohort$aggregation,
    feature_dimension = ncol(X), external_validation = "none",
    titan_feature_file_sha256 = cohort$source_sha256,
    feature_schema_sha256 = digest::digest(cohort$feature_names, algo = "sha256"),
    prediction_rule = "fitted PLS-LDA class; score > 0 favours class 1; score is not calibrated",
    endpoint_transform = "none",
    output_units = "class label and uncalibrated LDA score",
    class_labels = "0=wild type/negative; 1=altered/positive",
    class_priors = paste0(
      "0=", formatC(mean(y == "0"), digits = 6L, format = "f"),
      "; 1=", formatC(mean(y == "1"), digits = 6L, format = "f")
    ),
    calibration_status = "not evaluated; LDA score is not a calibrated probability",
    fastPLS_version = fastpls_version,
    fastPLS_remote_sha = fastpls_remote_sha, backend = backend,
    svd_method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    fit_seed = fit_seed,
    analysis_fingerprint = analysis_fingerprint,
    contains_patient_level_training_rows = FALSE,
    intended_use = "Research use only; TCGA discovery model without external validation",
    redistribution_status = paste(
      "private TITAN-derived artifact; non-commercial academic research only;",
      "public redistribution prohibited unless the TITAN rights holder grants permission"
    )
  )
  saveRDS(list(analysis_fingerprint = analysis_fingerprint,
               repeats = repeat_rows, predictions = prediction_rows,
               registry = registry), checkpoint)
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

expected_ids <- c(
  vapply(seq_len(nrow(continuous_jobs)), function(i) {
    safe_name(continuous_jobs$family[i], continuous_jobs$tumor_type[i],
              continuous_jobs$endpoint[i])
  }, character(1)),
  vapply(seq_len(nrow(binary_jobs)), function(i) {
    safe_name(binary_jobs$family[i], binary_jobs$tumor_type[i],
              binary_jobs$endpoint[i])
  }, character(1))
)
if (anyDuplicated(expected_ids)) stop("Selected endpoints produced duplicate model IDs")
expected_checkpoints <- file.path(checkpoint_dir, paste0(expected_ids, ".rds"))
if (!all(file.exists(expected_checkpoints))) {
  stop("At least one selected robustness/model checkpoint is missing")
}
objects <- lapply(expected_checkpoints, readRDS)
if (!all(vapply(objects, function(z) {
  identical(z$analysis_fingerprint, analysis_fingerprint)
}, logical(1)))) {
  stop("At least one selected checkpoint has a stale analysis fingerprint")
}
reuse_audit <- rbindlist(lapply(objects, function(z) {
  if (!is.null(z$provenance_reuse_audit)) z$provenance_reuse_audit else NULL
}), fill = TRUE)
fwrite(reuse_audit, "results/tables/robustness_checkpoint_reuse_audit.csv")
continuous_repeats <- rbindlist(lapply(objects, function(z) {
  if (z$registry$outcome_type == "continuous") z$repeats else NULL
}), fill = TRUE)
binary_repeats <- rbindlist(lapply(objects, function(z) {
  if (z$registry$outcome_type == "binary") z$repeats else NULL
}), fill = TRUE)
registry <- rbindlist(lapply(objects, `[[`, "registry"), fill = TRUE)
continuous_predictions <- rbindlist(lapply(objects, function(z) {
  if (z$registry$outcome_type == "continuous") z$predictions else NULL
}), fill = TRUE)
binary_predictions <- rbindlist(lapply(objects, function(z) {
  if (z$registry$outcome_type == "binary") z$predictions else NULL
}), fill = TRUE)
setorder(registry, family, cancer_type, endpoint)
fwrite(continuous_repeats, "results/tables/continuous_repeated_nested_cv.csv")
fwrite(binary_repeats, "results/tables/binary_repeated_nested_cv.csv")
fwrite(registry, "models/model_registry.csv")
fwrite(continuous_predictions,
       "results/predictions/continuous_repeated_oof_predictions.csv.gz")
fwrite(binary_predictions,
       "results/predictions/binary_repeated_oof_predictions.csv.gz")
registered_model_files <- normalizePath(
  registry$file, mustWork = TRUE
)
existing_model_files <- list.files(
  "models", pattern = "[.]rds$", full.names = TRUE, recursive = FALSE
)
existing_model_files <- normalizePath(existing_model_files, mustWork = TRUE)
stale_model_files <- setdiff(existing_model_files, registered_model_files)
if (length(stale_model_files)) {
  removed <- unlink(stale_model_files)
  if (any(removed != 0L)) stop("Failed to remove stale TITAN model artifacts")
}
cat("saved research models:", nrow(registry),
    "; provenance-audited checkpoints reused:", nrow(reuse_audit),
    "; stale unregistered artifacts removed:", length(stale_model_files), "\n")
