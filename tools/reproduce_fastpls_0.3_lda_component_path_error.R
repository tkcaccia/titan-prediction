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

# Fully synthetic grouped binary example. The group and class counts reproduce
# the structure of the ACC-WNT task that exposed the failure, but no TCGA data
# are needed.
set.seed(1L)
X <- matrix(rnorm(53L * 768L), nrow = 53L, ncol = 768L)
y <- factor(
  c(rep(0L, 30L), rep(1L, 18L), 1L, 0L, 0L, 0L, 1L),
  levels = c(0L, 1L)
)
group <- c(rep("OR", 48L), "OU", "PA", rep("PK", 3L))

cat("Synthetic input: n=", nrow(X), ", p=", ncol(X),
    ", classes=", paste(table(y), collapse = "/"),
    ", groups=", length(unique(group)), "\n", sep = "")

call_single <- function(ncomp) {
  fastPLS::pls.single.cv(
    X, y,
    ncomp = ncomp,
    constrain = group,
    kfold = 5L,
    classifier = "lda",
    selection = "balanced_accuracy",
    scaling = "centering",
    backend = "cpu",
    seed = 20262901L,
    fit = FALSE
  )
}

single_one <- call_single(1L)
stopifnot(is.list(single_one), identical(single_one$best_ncomp, 1L))
cat("pls.single.cv(), ncomp=1: OK\n")

single_path <- call_single(1:10)
single_repeat <- call_single(1:10)
stopifnot(
  identical(as.integer(single_path$ncomp), 1:10),
  identical(single_path$class_pred, single_repeat$class_pred),
  identical(single_path$lda_scores, single_repeat$lda_scores),
  all(is.finite(single_path$selection_values)),
  all(is.finite(single_path$lda_scores)),
  identical(dim(single_path$effective_ncomp), c(4L, 10L)),
  all(single_path$effective_ncomp <= matrix(1:10, 4L, 10L, byrow = TRUE))
)
cat("pls.single.cv(), ncomp=1:10: OK; complete path retained; finite and deterministic\n\n")

call_double <- function(ncomp) {
  fastPLS::pls.double.cv(
    X, y,
    ncomp = ncomp,
    constrain = group,
    kfold_outer = 5L,
    kfold_inner = 5L,
    classifier = "lda",
    selection = "balanced_accuracy",
    scaling = "centering",
    backend = "cpu",
    seed = 20262901L,
    perm.test = FALSE
  )
}

double_one <- call_double(1L)
stopifnot(is.list(double_one), all(is.finite(double_one$Ypred)))
cat("pls.double.cv(), ncomp=1: OK\n")

double_path <- call_double(1:10)
double_repeat <- call_double(1:10)
stopifnot(
  identical(double_path$Ypred, double_repeat$Ypred),
  identical(double_path$results[[1L]]$score,
            double_repeat$results[[1L]]$score),
  all(!is.na(double_path$Ypred)),
  all(is.finite(double_path$results[[1L]]$score)),
  all(vapply(
    double_path$results[[1L]]$inner,
    function(item) identical(as.integer(item$ncomp), 1:10),
    logical(1)
  )),
  all(double_path$results[[1L]]$effective_ncomp >= 0L),
  all(double_path$results[[1L]]$effective_ncomp <= 10L)
)
cat("pls.double.cv(), ncomp=1:10: OK; complete inner paths retained; finite and deterministic\n")
cat("All grouped PLS-LDA component-path regression gates passed.\n")
