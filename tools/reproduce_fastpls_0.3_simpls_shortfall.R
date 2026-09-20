.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
})
source("R/utils.R")
cfg <- load_project_config()
models <- c("TITAN", "GigaSSL", "ProvGigaPath")
cohorts <- setNames(lapply(models, function(model) {
  readRDS(file.path("data/processed", paste0("patient_cohort_", model, ".rds")))
}), models)
common_patients <- Reduce(intersect, lapply(cohorts, function(x) rownames(x$X)))
d <- readRDS("data/processed/continuous_targets.rds")
d <- d[
  family == "thorsson" & tumor_type == "ACC" &
    endpoint == "T Cells CD4 Memory Activated" &
    patient %chin% common_patients & is.finite(value)
]
setorder(d, patient)
y <- d$value
job_id <- 625L
seed <- cfg$analysis$seed + job_id
outer <- random_folds(length(y), cfg$analysis$outer_folds, seed)
cat("fastPLS", as.character(packageVersion("fastPLS")),
    "RemoteSha", packageDescription("fastPLS")$RemoteSha, "\n")
cat("endpoint_n", length(y), "seed", seed,
    "components", paste(cfg$analysis$components, collapse = ","), "\n")

for (model in models) {
  idx <- match(d$patient, rownames(cohorts[[model]]$X))
  X <- cohorts[[model]]$X[idx, , drop = FALSE]
  cat("MODEL", model, "n", nrow(X), "p", ncol(X), "\n")
  for (fold in seq_len(cfg$analysis$outer_folds)) {
    train <- outer != fold
    Xtrain <- X[train, , drop = FALSE]
    ytrain <- y[train]
    cat(" outer_fold", fold, "train_n", sum(train), "test_n", sum(!train),
        "y_sd", format(sd(ytrain), digits = 17),
        "matrix_rank", qr(Xtrain)$rank, "\n")
    inner <- tryCatch(
      fastPLS::pls.single.cv(
        Xtrain, ytrain, ncomp = cfg$analysis$components,
        kfold = cfg$analysis$inner_folds, seed = seed + fold,
        fit = FALSE
      ),
      error = function(e) e
    )
    if (inherits(inner, "error")) {
      cat(" FAIL during pls.single.cv:", conditionMessage(inner), "\n")
      quit(status = 2L)
    }
    cat("  best_ncomp", inner$best_ncomp, "\n")
    final <- tryCatch(
      fastPLS::pls(
        Xtrain, ytrain, ncomp = inner$best_ncomp,
        fit = TRUE, return_loadings = TRUE,
        seed = seed + 100L + fold
      ),
      error = function(e) e
    )
    if (inherits(final, "error")) {
      cat(" FAIL during final pls:", conditionMessage(final), "\n")
      quit(status = 3L)
    }
  }
}
cat("No failure reproduced\n")
