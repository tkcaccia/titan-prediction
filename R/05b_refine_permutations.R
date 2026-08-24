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
workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
future::plan(future::multicore, workers = workers)

monte_carlo_interval <- function(exceedances, permutations, conf.level = 0.95) {
  b <- as.integer(exceedances)
  B <- as.integer(permutations)
  alpha <- 1 - conf.level
  c(
    lower = if (b == 0L) 0 else qbeta(alpha / 2, b, B - b + 1L),
    upper = if (b == B) 1 else qbeta(1 - alpha / 2, b + 1L, B - b)
  )
}

continuous_targets <- readRDS("data/processed/continuous_targets.rds")
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)

candidate_files <- function(directory, kind, stage) {
  files <- list.files(directory, pattern = "[.]rds$", full.names = TRUE)
  files[vapply(files, function(path) {
    z <- readRDS(path)$row
    effect_ok <- if (kind == "continuous") {
      is.finite(z$q2) && z$q2 >= cfg$analysis$continuous_effect_gate
    } else {
      is.finite(z$adjusted_balanced_accuracy) &&
        z$adjusted_balanced_accuracy >= cfg$analysis$binary_adjusted_ba_gate
    }
    if (stage == "initial") {
      isTRUE(effect_ok && z$permutations == 0L)
    } else {
      # Every effect-eligible endpoint is capable of changing rank after a
      # higher-resolution run. Include completed and conservatively
      # early-stopped 99-permutation jobs; the latter resume from the exact
      # number actually attempted rather than skipping unused indices.
      isTRUE(effect_ok && z$permutations == cfg$analysis$initial_permutations)
    }
  }, logical(1))]
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

run_sequential_permutations <- function(metric_function, X, y, job, times,
                                        loss_metric, existing_exceedances = 0L,
                                        start_index = 1L) {
  exceed <- as.integer(existing_exceedances)
  attempted <- 0L
  # Five exceedances make the minimum possible 99-permutation finite p-value
  # 0.06. For the 999 stage, 49 exceedances make it 0.05. Stopping at these
  # boundaries and assigning p=1 is conservative and cannot discard an
  # endpoint capable of raw p<0.05 (and hence cannot discard an FDR result).
  stop_exceedances <- if (times == cfg$analysis$initial_permutations) 5L else 49L
  observed <- if (loss_metric) as.numeric(job$rmse) else as.numeric(job$balanced_accuracy)
  for (i in seq.int(start_index, times)) {
    value <- metric_function(X, y, job, i)
    attempted <- attempted + 1L
    exceed <- exceed + if (loss_metric) value <= observed else value >= observed
    if (exceed >= stop_exceedances) break
  }
  stopped <- exceed >= stop_exceedances && (start_index + attempted - 1L) < times
  list(
    exceedances = exceed,
    attempted = attempted,
    stopped_early = stopped,
    p_value = if (stopped) 1 else (1 + exceed) / (times + 1)
  )
}

refine_continuous <- function(path, times) {
  old <- readRDS(path)
  job <- old$row
  if (!"permutation_attempted" %in% names(job)) {
    job[, permutation_attempted := as.integer(permutations)]
  }
  d <- continuous_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx) & is.finite(d$value)
  X <- cohort$X[idx[keep], , drop = FALSE]
  y <- d$value[keep]
  extending <- job$permutations == cfg$analysis$initial_permutations
  existing_attempted <- if (extending) {
    ifelse(is.na(job$permutation_attempted),
           cfg$analysis$initial_permutations,
           as.integer(job$permutation_attempted))
  } else 0L
  perm <- run_sequential_permutations(
    permuted_continuous_metric, X, y, job, times, loss_metric = TRUE,
    existing_exceedances = if (extending) job$permutation_exceedances else 0L,
    start_index = if (extending) existing_attempted + 1L else 1L
  )
  mc <- if (!perm$stopped_early) {
    monte_carlo_interval(perm$exceedances, times)
  } else c(lower = NA_real_, upper = NA_real_)
  job[, `:=`(
    p_permutation = perm$p_value,
    permutations = times,
    permutation_exceedances = perm$exceedances,
    permutation_attempted = fifelse(
      extending,
      existing_attempted + perm$attempted,
      perm$attempted
    ),
    permutation_stopped_early = perm$stopped_early,
    p_mc_lower_95 = mc[["lower"]],
    p_mc_upper_95 = mc[["upper"]],
    p_mc_status = if (perm$stopped_early) {
      "not estimated: conservative early stop and p=1 assignment"
    } else {
      "two-sided 95% Clopper-Pearson interval for the null exceedance probability"
    },
    backend = backend, svd_method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power
  )]
  old$row <- job
  saveRDS(old, path)
  NULL
}

refine_binary <- function(path, times) {
  old <- readRDS(path)
  job <- old$row
  if (!"permutation_attempted" %in% names(job)) {
    job[, permutation_attempted := as.integer(permutations)]
  }
  d <- binary_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx) & d$value %in% c(0L, 1L)
  X <- cohort$X[idx[keep], , drop = FALSE]
  y <- factor(d$value[keep], levels = c(0L, 1L))
  extending <- job$permutations == cfg$analysis$initial_permutations
  existing_attempted <- if (extending) {
    ifelse(is.na(job$permutation_attempted),
           cfg$analysis$initial_permutations,
           as.integer(job$permutation_attempted))
  } else 0L
  perm <- run_sequential_permutations(
    permuted_binary_metric, X, y, job, times, loss_metric = FALSE,
    existing_exceedances = if (extending) job$permutation_exceedances else 0L,
    start_index = if (extending) existing_attempted + 1L else 1L
  )
  mc <- if (!perm$stopped_early) {
    monte_carlo_interval(perm$exceedances, times)
  } else c(lower = NA_real_, upper = NA_real_)
  job[, `:=`(
    p_permutation = perm$p_value,
    permutations = times,
    permutation_exceedances = perm$exceedances,
    permutation_attempted = fifelse(
      extending,
      existing_attempted + perm$attempted,
      perm$attempted
    ),
    permutation_stopped_early = perm$stopped_early,
    p_mc_lower_95 = mc[["lower"]],
    p_mc_upper_95 = mc[["upper"]],
    p_mc_status = if (perm$stopped_early) {
      "not estimated: conservative early stop and p=1 assignment"
    } else {
      "two-sided 95% Clopper-Pearson interval for the null exceedance probability"
    },
    backend = backend, svd_method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power
  )]
  old$row <- job
  saveRDS(old, path)
  NULL
}

audit_permutation_state <- function(directory) {
  files <- list.files(directory, pattern = "[.]rds$", full.names = TRUE)
  invalid <- files[vapply(files, function(path) {
    row <- readRDS(path)$row
    attempted <- if ("permutation_attempted" %in% names(row)) {
      as.integer(row$permutation_attempted)
    } else NA_integer_
    target <- as.integer(row$permutations)
    (target == 0L && !is.na(attempted) && attempted != 0L) ||
      (target > 0L && (is.na(attempted) || attempted > target))
  }, logical(1))]
  if (length(invalid)) {
    stop(
      "Invalid legacy permutation checkpoint metadata in ", length(invalid),
      " files under ", directory,
      ". Reset or regenerate these checkpoints before refinement; no ",
      "permutation indices will be guessed or skipped. First file: ",
      invalid[[1L]]
    )
  }
  invisible(TRUE)
}

audit_permutation_state("data/processed/checkpoints/continuous")
audit_permutation_state("data/processed/checkpoints/binary")

continuous_initial <- candidate_files(
  "data/processed/checkpoints/continuous", "continuous", "initial"
)
binary_initial <- candidate_files(
  "data/processed/checkpoints/binary", "binary", "initial"
)
# Borderline effects are evaluated first because null-like candidates reach the
# conservative stopping boundary quickly; this improves checkpoint throughput
# without changing any statistic or seed.
continuous_initial <- continuous_initial[order(vapply(
  continuous_initial, function(path) readRDS(path)$row$q2, numeric(1)
))]
binary_initial <- binary_initial[order(vapply(
  binary_initial,
  function(path) readRDS(path)$row$adjusted_balanced_accuracy, numeric(1)
))]
message("Running 99 permutations for ", length(continuous_initial),
        " continuous and ", length(binary_initial), " binary candidates")
invisible(future_lapply(
  continuous_initial, refine_continuous,
  times = cfg$analysis$initial_permutations, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table"), future.globals = TRUE,
  future.chunk.size = 1
))
invisible(future_lapply(
  binary_initial, refine_binary,
  times = cfg$analysis$initial_permutations, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table"), future.globals = TRUE,
  future.chunk.size = 1
))

continuous_extended <- candidate_files(
  "data/processed/checkpoints/continuous", "continuous", "extended"
)
binary_extended <- candidate_files(
  "data/processed/checkpoints/binary", "binary", "extended"
)
continuous_extended <- continuous_extended[order(vapply(
  continuous_extended, function(path) readRDS(path)$row$q2, numeric(1)
))]
binary_extended <- binary_extended[order(vapply(
  binary_extended,
  function(path) readRDS(path)$row$adjusted_balanced_accuracy,
  numeric(1)
))]
run_extended <- !identical(tolower(Sys.getenv("TITAN_RUN_999", "true")), "false")
if (run_extended) {
  message("Extending ", length(continuous_extended), " continuous and ",
          length(binary_extended), " binary candidates to 999 permutations")
  invisible(future_lapply(
    continuous_extended, refine_continuous,
    times = cfg$analysis$extended_permutations, future.seed = TRUE,
    future.packages = c("fastPLS", "data.table"), future.globals = TRUE,
    future.chunk.size = 1
  ))
  invisible(future_lapply(
    binary_extended, refine_binary,
    times = cfg$analysis$extended_permutations, future.seed = TRUE,
    future.packages = c("fastPLS", "data.table"), future.globals = TRUE,
    future.chunk.size = 1
  ))
} else {
  message("Skipping primary 999-permutation refinement because TITAN_RUN_999=false")
}

collate <- function(directory, kind) {
  objects <- lapply(list.files(directory, pattern = "[.]rds$", full.names = TRUE), readRDS)
  results <- rbindlist(lapply(objects, `[[`, "row"), fill = TRUE)
  effect_ok <- if (kind == "continuous") {
    is.finite(results$q2) & results$q2 >= cfg$analysis$continuous_effect_gate
  } else {
    is.finite(results$adjusted_balanced_accuracy) &
      results$adjusted_balanced_accuracy >= cfg$analysis$binary_adjusted_ba_gate
  }
  if (!"p_mc_lower_95" %in% names(results)) results[, p_mc_lower_95 := NA_real_]
  if (!"p_mc_upper_95" %in% names(results)) results[, p_mc_upper_95 := NA_real_]
  if (!"p_mc_status" %in% names(results)) results[, p_mc_status := NA_character_]
  completed <- effect_ok & !results$permutation_stopped_early
  if (any(completed)) {
    mc <- t(vapply(which(completed), function(i) {
      monte_carlo_interval(
        results$permutation_exceedances[[i]], results$permutations[[i]]
      )
    }, numeric(2L)))
    results[completed, `:=`(
      p_mc_lower_95 = mc[, "lower"],
      p_mc_upper_95 = mc[, "upper"],
      p_mc_status = paste0(
        "two-sided 95% Clopper-Pearson interval for ",
        "the null exceedance probability"
      )
    )]
  }
  results[effect_ok & permutation_stopped_early, `:=`(
    p_mc_lower_95 = NA_real_, p_mc_upper_95 = NA_real_,
    p_mc_status = "not estimated: conservative early stop and p=1 assignment"
  )]
  results[!effect_ok, `:=`(
    p_mc_lower_95 = NA_real_, p_mc_upper_95 = NA_real_,
    p_mc_status = "not permutation-tested: below the prespecified effect gate"
  )]
  # The primary scientific claim is a separate target screen within each
  # disease. Control FDR within cancer and prespecified endpoint family, while
  # retaining the more stringent across-cancer family q value as sensitivity.
  results[, q_value := p.adjust(p_permutation, method = "BH"),
          by = .(family, tumor_type)]
  results[, q_value_global := p.adjust(p_permutation, method = "BH"),
          by = family]
  results[, q_value_outcome_wide := p.adjust(p_permutation, method = "BH")]
  if (kind == "continuous") {
    results[, tier := fifelse(
      q_value < cfg$analysis$fdr_alpha & q2 >= 0.40, "A",
      fifelse(q_value < cfg$analysis$fdr_alpha & q2 >= 0.20, "B", "C")
    )]
    setorder(results, family, -q2)
  } else {
    results[, tier := fifelse(
      q_value < cfg$analysis$fdr_alpha & adjusted_balanced_accuracy >= 0.40, "A",
      fifelse(q_value < cfg$analysis$fdr_alpha &
                adjusted_balanced_accuracy >= 0.20, "B", "C")
    )]
    setorder(results, family, -balanced_accuracy)
  }
  list(results = results, objects = objects)
}

continuous_collated <- collate(
  "data/processed/checkpoints/continuous", "continuous"
)
binary_collated <- collate("data/processed/checkpoints/binary", "binary")
atlas_p <- p.adjust(c(
  continuous_collated$results$p_permutation,
  binary_collated$results$p_permutation
), method = "BH")
continuous_collated$results[, q_value_atlas_wide :=
  atlas_p[seq_len(nrow(continuous_collated$results))]]
binary_collated$results[, q_value_atlas_wide := atlas_p[
  nrow(continuous_collated$results) + seq_len(nrow(binary_collated$results))
]]

write_collated <- function(x, kind) {
  screen <- copy(x$results)
  screen[, c(
    "p_mc_lower_95", "p_mc_upper_95", "p_mc_status",
    "q_value_outcome_wide", "q_value_atlas_wide"
  ) := NULL]
  fwrite(screen, file.path("results/tables", paste0(kind, "_screen.csv")))
  saveRDS(
    lapply(x$objects, `[[`, "predictions"),
    file.path("results/predictions", paste0(kind, "_oof_predictions.rds")),
    compress = "xz"
  )
}
write_collated(continuous_collated, "continuous")
write_collated(binary_collated, "binary")

uncertainty <- rbindlist(list(
  continuous_collated$results[, .(
    outcome_type = "continuous", family, tumor_type, endpoint,
    p_permutation, permutations, permutation_exceedances,
    permutation_attempted, permutation_stopped_early,
    p_mc_lower_95, p_mc_upper_95, p_mc_status
  )],
  binary_collated$results[, .(
    outcome_type = "binary", family, tumor_type, endpoint,
    p_permutation, permutations, permutation_exceedances,
    permutation_attempted, permutation_stopped_early,
    p_mc_lower_95, p_mc_upper_95, p_mc_status
  )]
), use.names = TRUE)
fwrite(uncertainty, "results/tables/permutation_monte_carlo_uncertainty.csv")

multiplicity_by_endpoint <- rbindlist(list(
  continuous_collated$results[, .(
    outcome_type = "continuous", family, tumor_type, endpoint,
    p_permutation, q_value, q_value_global,
    q_value_outcome_wide, q_value_atlas_wide, tier
  )],
  binary_collated$results[, .(
    outcome_type = "binary", family, tumor_type, endpoint,
    p_permutation, q_value, q_value_global,
    q_value_outcome_wide, q_value_atlas_wide, tier
  )]
), use.names = TRUE)
fwrite(
  multiplicity_by_endpoint,
  "results/tables/multiplicity_sensitivity_by_endpoint.csv"
)

summarise_multiplicity <- function(z, kind) {
  effect_ok <- if (kind == "continuous") {
    is.finite(z$q2) & z$q2 >= cfg$analysis$continuous_effect_gate
  } else {
    is.finite(z$adjusted_balanced_accuracy) &
      z$adjusted_balanced_accuracy >= cfg$analysis$binary_adjusted_ba_gate
  }
  screen_positive <- z$tier %chin% c("A", "B")
  data.table(
    outcome_type = kind,
    eligible_tests = nrow(z),
    effect_eligible = sum(effect_ok),
    within_cancer_family_candidates = sum(screen_positive),
    across_cancer_family_pass = sum(screen_positive & z$q_value_global < 0.05),
    outcome_wide_pass = sum(screen_positive & z$q_value_outcome_wide < 0.05),
    atlas_wide_pass = sum(screen_positive & z$q_value_atlas_wide < 0.05)
  )
}
multiplicity_summary <- rbindlist(list(
  summarise_multiplicity(continuous_collated$results, "continuous"),
  summarise_multiplicity(binary_collated$results, "binary")
))
multiplicity_summary <- rbind(
  multiplicity_summary,
  data.table(
    outcome_type = "combined",
    eligible_tests = sum(multiplicity_summary$eligible_tests),
    effect_eligible = sum(multiplicity_summary$effect_eligible),
    within_cancer_family_candidates =
      sum(multiplicity_summary$within_cancer_family_candidates),
    across_cancer_family_pass =
      sum(multiplicity_summary$across_cancer_family_pass),
    outcome_wide_pass = sum(multiplicity_summary$outcome_wide_pass),
    atlas_wide_pass = sum(multiplicity_summary$atlas_wide_pass)
  )
)
fwrite(multiplicity_summary, "results/tables/multiplicity_sensitivity_summary.csv")
