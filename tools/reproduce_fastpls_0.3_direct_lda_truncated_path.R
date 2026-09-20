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

# Nine observations have a centered predictor-rank ceiling of eight. The
# requested classification path deliberately extends to ten components.
set.seed(42L)
X <- matrix(rnorm(9L * 20L), nrow = 9L, ncol = 20L)
y <- factor(c(0L, 0L, 0L, 0L, 0L, 1L, 1L, 1L, 1L),
            levels = c(0L, 1L))

# Use the fastPLS defaults, including the package-default rSVD settings.
fit <- fastPLS::pls(
  X, y,
  ncomp = 1:10,
  classifier = "lda",
  fit = TRUE,
  return_loadings = FALSE,
  seed = 77L
)
prediction <- predict(fit, X[1:3, , drop = FALSE], raw_scores = TRUE)

cat("Requested components: 1:10\n")
cat("Returned effective_ncomp:", paste(fit$effective_ncomp, collapse = ","), "\n")
cat("LDA score dimensions:", paste(dim(prediction$LDA_scores), collapse = " x "), "\n")
cat("Class-prediction dimensions:", paste(dim(prediction$Ypred), collapse = " x "), "\n")

# Acceptance conditions. These currently fail because direct fitted-model
# prediction returns only eight prefixes rather than retaining the requested
# ten-prefix path and repeating prefix eight for requests nine and ten.
stopifnot(
  identical(as.integer(fit$effective_ncomp), c(1:8, 8L, 8L)),
  identical(dim(prediction$LDA_scores), c(3L, 2L, 10L)),
  identical(dim(prediction$Ypred), c(3L, 10L)),
  all(prediction$LDA_scores[, , 9L] == prediction$LDA_scores[, , 8L]),
  all(prediction$LDA_scores[, , 10L] == prediction$LDA_scores[, , 8L]),
  all(prediction$Ypred[, 9L] == prediction$Ypred[, 8L]),
  all(prediction$Ypred[, 10L] == prediction$Ypred[, 8L])
)

cat("Direct PLS-LDA truncated-component path retained correctly.\n")
