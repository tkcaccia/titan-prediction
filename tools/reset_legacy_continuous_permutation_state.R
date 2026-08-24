.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages(library(data.table))
source("R/utils.R")
cfg <- load_project_config()

checkpoint_dir <- "data/processed/checkpoints/continuous"
archive_dir <- file.path(
  "data/processed/checkpoints",
  paste0("archive_legacy_continuous_permutations_", format(Sys.Date(), "%Y%m%d"))
)
dir.create(archive_dir, recursive = TRUE, showWarnings = FALSE)

files <- list.files(checkpoint_dir, pattern = "[.]rds$", full.names = TRUE)
reset <- 0L
for (path in files) {
  object <- readRDS(path)
  row <- object$row
  effect_eligible <- is.finite(row$q2) &&
    row$q2 >= cfg$analysis$continuous_effect_gate
  if (!effect_eligible) next

  archive_path <- file.path(archive_dir, basename(path))
  if (!file.exists(archive_path)) {
    ok <- file.copy(path, archive_path, overwrite = FALSE)
    if (!ok) stop("Could not archive ", path)
  }
  row[, `:=`(
    p_permutation = 1,
    permutations = 0L,
    permutation_exceedances = NA_integer_,
    permutation_attempted = 0L,
    permutation_stopped_early = FALSE
  )]
  object$row <- row
  saveRDS(object, path)
  reset <- reset + 1L
}

cat("reset", reset, "screening-threshold-eligible continuous checkpoints; archive:",
    archive_dir, "\n")
