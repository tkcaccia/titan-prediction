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
fastpls_description <- packageDescription("fastPLS")
fastpls_remote_sha <- as.character(fastpls_description$RemoteSha)
if (!length(fastpls_remote_sha) || is.na(fastpls_remote_sha)) {
  fastpls_remote_sha <- "not-recorded"
}
workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
future::plan(future::multicore, workers = workers)
run_refinement <- !identical(
  tolower(Sys.getenv("TITAN_RUN_9999", "true")), "false"
)
if (!run_refinement) {
  message("Skipping targeted 9,999-permutation refinement because TITAN_RUN_9999=false")
  quit(save = "no", status = 0L)
}

target_B <- as.integer(Sys.getenv("TITAN_TARGETED_PERMUTATIONS", "9999"))
if (target_B < 9999L) stop("targeted_permutations must be at least 9,999")
targets <- fread("data/reference/targeted_permutation_refinement_targets.csv")
key <- c("outcome_type", "family", "tumor_type", "endpoint")
if (anyDuplicated(targets, by = key)) stop("Targeted permutation keys are duplicated")
if (!all(targets$outcome_type %chin% c("continuous", "binary"))) {
  stop("Unknown outcome type in targeted permutation registry")
}

cohort <- readRDS("data/processed/patient_cohort.rds")
continuous_targets <- readRDS("data/processed/continuous_targets.rds")
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)
continuous_screen <- fread("results/tables/continuous_screen.csv")
binary_screen <- fread("results/tables/binary_screen.csv")

checkpoint_dir <- "data/processed/checkpoints/targeted_permutation_refinement"
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)

monte_carlo_interval <- function(exceedances, permutations, conf.level = 0.95) {
  b <- as.integer(exceedances)
  B <- as.integer(permutations)
  alpha <- 1 - conf.level
  c(
    lower = if (b == 0L) 0 else qbeta(alpha / 2, b, B - b + 1L),
    upper = if (b == B) 1 else qbeta(1 - alpha / 2, b + 1L, B - b)
  )
}

permuted_continuous_metric <- function(X, y, job, permutation_index) {
  set.seed(as.integer(job$seed) + 500000L + permutation_index)
  shuffled <- sample.int(nrow(X))
  fit <- pls.double.cv(
    X[shuffled, , drop = FALSE], y,
    ncomp = cfg$analysis$components,
    scaling = "centering",
    svd.method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    kfold_outer = cfg$analysis$outer_folds,
    kfold_inner = cfg$analysis$inner_folds,
    seed = as.integer(job$seed) + 3000L + permutation_index,
    perm.test = FALSE
  )
  as.numeric(fit$RMSD[[1L]])
}

permuted_binary_metric <- function(X, y, job, permutation_index) {
  set.seed(as.integer(job$seed) + 500000L + permutation_index)
  shuffled <- sample.int(nrow(X))
  fit <- pls.double.cv(
    Xdata = X[shuffled, , drop = FALSE], Ydata = y,
    ncomp = cfg$analysis$components,
    scaling = "centering",
    classifier = "lda", lda_ridge = cfg$analysis$lda_ridge,
    selection_metric = "balanced_accuracy",
    svd.method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    kfold_outer = cfg$analysis$outer_folds,
    kfold_inner = cfg$analysis$inner_folds,
    seed = as.integer(job$seed) + 3000L + permutation_index,
    perm.test = FALSE
  )
  as.numeric(fit$balanced_accuracy[[1L]])
}

safe_id <- function(x) {
  gsub("(^_+|_+$)", "", gsub("[^A-Za-z0-9]+", "_", x))
}

refine_one <- function(i) {
  target <- targets[i]
  screen <- if (target$outcome_type == "continuous") {
    continuous_screen
  } else {
    binary_screen
  }
  job <- screen[
    family == target$family & tumor_type == target$tumor_type &
      endpoint == target$endpoint
  ]
  if (nrow(job) != 1L) {
    stop("Targeted screen row not found uniquely: ", paste(target[, ..key], collapse = " | "))
  }
  if (job$permutations != cfg$analysis$extended_permutations ||
      isTRUE(job$permutation_stopped_early)) {
    stop("Targeted refinement requires a completed 999-permutation checkpoint: ",
         target$tumor_type, "--", target$endpoint)
  }

  if (target$outcome_type == "continuous") {
    d <- continuous_targets[
      family == target$family & tumor_type == target$tumor_type &
        endpoint == target$endpoint
    ]
    idx <- match(d$patient, rownames(cohort$X))
    keep <- !is.na(idx) & is.finite(d$value)
    X <- cohort$X[idx[keep], , drop = FALSE]
    y <- d$value[keep]
    observed <- as.numeric(job$rmse)
    loss_metric <- TRUE
    metric_function <- permuted_continuous_metric
  } else {
    d <- binary_targets[
      family == target$family & tumor_type == target$tumor_type &
        endpoint == target$endpoint
    ]
    idx <- match(d$patient, rownames(cohort$X))
    keep <- !is.na(idx) & d$value %in% c(0L, 1L)
    X <- cohort$X[idx[keep], , drop = FALSE]
    y <- factor(d$value[keep], levels = c(0L, 1L))
    observed <- as.numeric(job$balanced_accuracy)
    loss_metric <- FALSE
    metric_function <- permuted_binary_metric
  }

  checkpoint_file <- file.path(
    checkpoint_dir,
    paste0(safe_id(paste(target[, ..key], collapse = "__")), ".rds")
  )
  if (file.exists(checkpoint_file)) {
    state <- readRDS(checkpoint_file)
    if (state$target_permutations != target_B ||
        state$primary_permutations != job$permutations) {
      stop("Incompatible targeted-refinement checkpoint: ", checkpoint_file)
    }
  } else {
    state <- list(
      outcome_type = target$outcome_type,
      family = target$family,
      tumor_type = target$tumor_type,
      endpoint = target$endpoint,
      target_permutations = target_B,
      primary_permutations = as.integer(job$permutations),
      attempted = as.integer(job$permutation_attempted),
      exceedances = as.integer(job$permutation_exceedances),
      next_index = as.integer(job$permutation_attempted) + 1L,
      backend = backend,
      svd_method = cfg$analysis$svd_method,
      rsvd_oversample = cfg$analysis$rsvd_oversample,
      rsvd_power = cfg$analysis$rsvd_power
    )
    saveRDS(state, checkpoint_file)
  }

  if (state$next_index <= target_B) {
    for (permutation_index in seq.int(state$next_index, target_B)) {
      value <- metric_function(X, y, job, permutation_index)
      state$attempted <- state$attempted + 1L
      state$exceedances <- state$exceedances + if (loss_metric) {
        value <= observed
      } else {
        value >= observed
      }
      state$next_index <- permutation_index + 1L
      if (permutation_index %% 50L == 0L || permutation_index == target_B) {
        saveRDS(state, checkpoint_file)
      }
      if (permutation_index %% 1000L == 0L) {
        message(target$tumor_type, "--", target$endpoint, ": ",
                permutation_index, "/", target_B)
      }
    }
  }
  if (state$attempted != target_B || state$next_index != target_B + 1L) {
    stop("Incomplete targeted refinement: ", target$tumor_type, "--", target$endpoint)
  }
  mc <- monte_carlo_interval(state$exceedances, target_B)
  data.table(
    outcome_type = target$outcome_type,
    family = target$family,
    tumor_type = target$tumor_type,
    endpoint = target$endpoint,
    selection_reason = target$selection_reason,
    n = as.integer(job$n),
    observed_metric = if (loss_metric) "RMSE (lower is more extreme)" else
      "balanced accuracy (higher is more extreme)",
    observed_value = observed,
    primary_p_999 = as.numeric(job$p_permutation),
    primary_exceedances_999 = as.integer(job$permutation_exceedances),
    refined_p_9999 = (1 + state$exceedances) / (target_B + 1),
    refined_exceedances_9999 = as.integer(state$exceedances),
    refined_permutations = target_B,
    refinement_stopped_early = FALSE,
    refined_mc_lower_95 = mc[["lower"]],
    refined_mc_upper_95 = mc[["upper"]],
    zero_exceedances = state$exceedances == 0L,
    full_nested_process_repeated = TRUE,
    scaling_relearned_within_folds = TRUE,
    inner_component_selection_repeated = TRUE,
    outer_predictions_regenerated = TRUE,
    refinement_use = paste0(
      "targeted Monte Carlo precision sensitivity only; not substituted into ",
      "the prespecified 999-permutation FDR screen"
    ),
    backend = backend,
    parallel_workers = workers,
    fastPLS_version = as.character(packageVersion("fastPLS")),
    fastPLS_remote_sha = fastpls_remote_sha,
    pls_method = "simpls",
    scaling = "centering",
    classifier = if (loss_metric) "not applicable" else "LDA",
    target_registry_git_commit = "ac30ccb",
    svd_method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    seed_rule = "primary seed + 500000 + permutation index; fit seed = primary seed + 3000 + permutation index"
  )
}

message("Refining ", nrow(targets), " prespecified leading models from 999 to ",
        target_B, " permutations")
refined <- rbindlist(future_lapply(
  seq_len(nrow(targets)), refine_one,
  future.seed = TRUE,
  future.packages = c("fastPLS", "data.table"),
  future.globals = TRUE,
  future.chunk.size = 1
))
setorder(refined, outcome_type, family, tumor_type, endpoint)
fwrite(refined, "results/tables/targeted_permutation_refinement.csv")
