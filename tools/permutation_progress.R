.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages(library(data.table))
source("R/utils.R")
cfg <- load_project_config()

summarise_kind <- function(kind) {
  directory <- file.path("data", "processed", "checkpoints", kind)
  files <- list.files(directory, pattern = "[.]rds$", full.names = TRUE)
  if (!length(files)) {
    return(data.table(
      outcome_type = kind, checkpoints = 0L, effect_eligible = 0L,
      rsvd_checkpoints = 0L,
      at_99_or_more = 0L, finalized_at_999 = 0L, early_stopped = 0L,
      attempted_permutations = 0L
    ))
  }
  rows <- rbindlist(lapply(files, function(path) readRDS(path)$row), fill = TRUE)
  effect_eligible <- if (kind == "continuous") {
    is.finite(rows$q2) & rows$q2 >= cfg$analysis$continuous_effect_gate
  } else {
    is.finite(rows$adjusted_balanced_accuracy) &
      rows$adjusted_balanced_accuracy >= cfg$analysis$binary_adjusted_ba_gate
  }
  attempted <- if ("permutation_attempted" %in% names(rows)) {
    fifelse(is.na(rows$permutation_attempted), 0L,
            as.integer(rows$permutation_attempted))
  } else {
    fifelse(is.na(rows$permutations), 0L, as.integer(rows$permutations))
  }
  stopped <- if ("permutation_stopped_early" %in% names(rows)) {
    rows$permutation_stopped_early %in% TRUE
  } else {
    rep(FALSE, nrow(rows))
  }
  rsvd_ready <- if (all(c("svd_method", "rsvd_oversample", "rsvd_power") %in%
                         names(rows))) {
    rows$svd_method == cfg$analysis$svd_method &
      rows$rsvd_oversample == cfg$analysis$rsvd_oversample &
      rows$rsvd_power == cfg$analysis$rsvd_power
  } else rep(FALSE, nrow(rows))
  data.table(
    outcome_type = kind,
    checkpoints = nrow(rows),
    effect_eligible = sum(effect_eligible),
    rsvd_checkpoints = sum(rsvd_ready, na.rm = TRUE),
    at_99_or_more = sum(effect_eligible & rows$permutations >=
                          cfg$analysis$initial_permutations),
    finalized_at_999 = sum(effect_eligible & rows$permutations >=
                             cfg$analysis$extended_permutations),
    early_stopped = sum(effect_eligible & stopped),
    attempted_permutations = sum(attempted[effect_eligible])
  )
}

progress <- rbindlist(lapply(c("continuous", "binary"), summarise_kind))
print(progress)
