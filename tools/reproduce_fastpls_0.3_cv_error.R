.libPaths(c(normalizePath(".Rlib", mustWork = TRUE), .libPaths()))
suppressPackageStartupMessages(library(fastPLS))

expected_version <- "0.3"
expected_sha <- "b518f75285c387632c2443a0c0989d75c9dcda48"
description <- packageDescription("fastPLS")
stopifnot(
  identical(as.character(packageVersion("fastPLS")), expected_version),
  identical(as.character(description$RemoteSha), expected_sha)
)

cat("fastPLS version:", description$Version, "\n")
cat("fastPLS Git commit:", description$RemoteSha, "\n")
cat("Compiled BLAS metadata:\n")
print(fastPLS_blas())
cat("Metal available:", has_metal(), "\n")
cat("CUDA available:", has_cuda(), "\n\n")

# Fully synthetic reproduction. The dimensions and response sparsity mirror
# the first failing TCGA task, but no project data are required.
set.seed(10L)
X <- matrix(rnorm(54L * 768L), nrow = 54L, ncol = 768L)
y <- c(rep(0, 52L), 0.00549885308390477, 0.0599934866563745)

cat("Synthetic input: n=", nrow(X), ", p=", ncol(X),
    ", unique(y)=", length(unique(y)), ", zeros(y)=", sum(y == 0), "\n",
    sep = "")

# This confirms that the renamed 0.3 fitting API is being used correctly.
direct <- fastPLS::pls(
  X, y, ncomp = 1L, backend = "cpu",
  seed = 20260852L
)
stopifnot(inherits(direct, "fastPLS"))
cat("Direct pls() fit: OK\n")

# Single CV succeeds on this synthetic example.
single <- fastPLS::pls.single.cv(
  X, y, ncomp = 1:10, kfold = 5L, backend = "cpu",
  seed = 20260852L,
  fit = FALSE
)
cat("Single CV: OK; selected", single$best_ncomp, "component(s)\n")

# Regression gate for the formerly failing nested-CV path. Each requested
# prefix must remain in every inner tuning path even if fewer effective PLS
# directions can be estimated in a degenerate fold.
run_nested <- function(ncomp, scaling, response = y) {
  fastPLS::pls.double.cv(
    X, response, ncomp = ncomp,
    kfold_outer = 5L, kfold_inner = 5L,
    scaling = scaling, backend = "cpu",
    seed = 20260852L,
    perm.test = FALSE
  )
}

for (scaling in c("centering", "autoscaling", "none")) {
  for (requested in list(1L, 1:10)) {
    nested <- run_nested(requested, scaling)
    stopifnot(
      length(nested$Ypred) == nrow(X),
      all(is.finite(nested$Ypred)),
      all(vapply(
        nested$results[[1]]$inner,
        function(item) identical(as.integer(item$ncomp), as.integer(requested)),
        logical(1)
      ))
    )
    nested_repeat <- run_nested(requested, scaling)
    stopifnot(identical(nested$Ypred, nested_repeat$Ypred))
    cat("Nested CV: OK; scaling=", scaling,
        "; requested components=", paste(requested, collapse = ","), "\n",
        sep = "")
  }
}

constant <- run_nested(1:10, "centering", rep(0.25, nrow(X)))
stopifnot(
  all(is.finite(constant$Ypred)),
  all(abs(as.numeric(constant$Ypred) - 0.25) < 1e-12),
  all(vapply(
    constant$results[[1]]$inner,
    function(item) identical(as.integer(item$ncomp), 1:10),
    logical(1)
  ))
)
cat("Constant-response nested CV: OK\n\n")

# Optional confirmation using the exact processed project task.
cohort_path <- "data/processed/patient_cohort.rds"
target_path <- "data/processed/continuous_targets.rds"
if (file.exists(cohort_path) && file.exists(target_path) &&
    requireNamespace("data.table", quietly = TRUE)) {
  cohort <- readRDS(cohort_path)
  targets <- data.table::as.data.table(readRDS(target_path))
  endpoint_data <- targets[
    family == "thorsson" & tumor_type == "ACC" &
      endpoint == "T Cells CD4 Memory Activated"
  ]
  index <- match(endpoint_data$patient, rownames(cohort$X))
  keep <- !is.na(index) & is.finite(endpoint_data$value)
  project_X <- cohort$X[index[keep], , drop = FALSE]
  project_y <- endpoint_data$value[keep]
  cat("Project input: n=", nrow(project_X), ", p=", ncol(project_X),
      ", unique(y)=", length(unique(project_y)),
      ", zeros(y)=", sum(project_y == 0), "\n", sep = "")
  project_fit <- fastPLS::pls.double.cv(
    project_X, project_y, ncomp = 1:10,
    kfold_outer = 5L, kfold_inner = 5L,
    backend = "cpu",
    seed = 20260852L, perm.test = FALSE
  )
  stopifnot(
    length(project_fit$Ypred) == nrow(project_X),
    all(is.finite(project_fit$Ypred)),
    all(vapply(
      project_fit$results[[1]]$inner,
      function(item) identical(as.integer(item$ncomp), 1:10),
      logical(1)
    ))
  )
  cat("Formerly failing project nested CV: OK\n")
}

cat("All fastPLS 0.3 regression gates passed.\n")
