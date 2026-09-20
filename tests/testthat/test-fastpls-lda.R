test_that("fixed fastPLS supports LDA in single and double cross-validation", {
  skip_if_not_installed("fastPLS")
  expect_identical(as.character(packageVersion("fastPLS")), "0.3")
  set.seed(11)
  x <- matrix(rnorm(60L * 12L), nrow = 60L, ncol = 12L)
  y <- factor(
    as.integer(x[, 1L] + 0.5 * x[, 2L] + rnorm(60L, sd = 0.7) > 0),
    levels = c(0L, 1L)
  )

  single <- fastPLS::pls.single.cv(
    x, y, ncomp = 1:2, kfold = 3L, seed = 99L,
    classifier = "lda", selection = "balanced_accuracy",
    fit = FALSE
  )
  expect_true(single$best_ncomp %in% 1:2)

  double <- fastPLS::pls.double.cv(
    x, y, ncomp = 1:2, kfold_outer = 3L, kfold_inner = 3L,
    seed = 99L, classifier = "lda", selection = "balanced_accuracy",
    perm.test = FALSE
  )
  expect_length(double$Ypred, nrow(x))
  expect_true(is.finite(as.numeric(double$balanced_accuracy[[1L]])))

  deployable <- fastPLS::pls(
    x, y, ncomp = single$best_ncomp, classifier = "lda",
    seed = 99L, fit = TRUE
  )
  expect_identical(deployable$diagnostics$solver, "rsvd")
  expect_identical(deployable$diagnostics$rsvd$oversample, 32L)
  expect_identical(deployable$diagnostics$rsvd$power, 5L)
})

test_that("continuous nested validation returns one prediction per held-out patient", {
  skip_if_not_installed("fastPLS")
  old <- getwd()
  on.exit(setwd(old), add = TRUE)
  root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
  setwd(root)
  source("R/utils.R")
  set.seed(217)
  x <- matrix(rnorm(72L * 12L), nrow = 72L, ncol = 12L)
  y <- 1.8 * x[, 1L] - 0.9 * x[, 2L] + rnorm(72L, sd = 0.35)
  cfg <- load_project_config()$analysis
  cfg$outer_folds <- 3L
  cfg$inner_folds <- 3L
  cfg$components <- 1:2

  result <- fit_continuous_nested_once(x, y, cfg, seed = 217L)

  expect_length(result$prediction, length(y))
  expect_false(anyNA(result$prediction))
  expect_true(all(vapply(
    split(result$prediction, result$fold),
    function(z) length(unique(signif(z, 12L))) > 1L,
    logical(1)
  )))
  expect_gt(result$q2, 0.5)
})
