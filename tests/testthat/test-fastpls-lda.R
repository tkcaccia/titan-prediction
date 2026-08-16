test_that("fixed fastPLS supports LDA in single and double cross-validation", {
  skip_if_not_installed("fastPLS")
  expect_identical(as.character(packageVersion("fastPLS")), "0.99.20")
  set.seed(11)
  x <- matrix(rnorm(60L * 12L), nrow = 60L, ncol = 12L)
  y <- factor(
    as.integer(x[, 1L] + 0.5 * x[, 2L] + rnorm(60L, sd = 0.7) > 0),
    levels = c(0L, 1L)
  )

  single <- fastPLS::pls.single.cv(
    x, y, ncomp = 1:2, kfold = 3L, seed = 99L,
    classifier = "lda", lda_ridge = 1e-6,
    selection_metric = "balanced_accuracy", svd.method = "rsvd",
    rsvd_oversample = 10L, rsvd_power = 2L,
    fit = FALSE
  )
  expect_true(single$best_ncomp %in% 1:2)

  double <- fastPLS::pls.double.cv(
    x, y, ncomp = 1:2, kfold_outer = 3L, kfold_inner = 3L,
    seed = 99L, classifier = "lda", lda_ridge = 1e-6,
    selection_metric = "balanced_accuracy", svd.method = "rsvd",
    rsvd_oversample = 10L, rsvd_power = 2L,
    perm.test = FALSE
  )
  expect_length(double$Ypred, nrow(x))
  expect_true(is.finite(as.numeric(double$balanced_accuracy[[1L]])))

  deployable <- fastPLS::pls(
    x, y, ncomp = single$best_ncomp, classifier = "lda",
    lda_ridge = 1e-6, svd.method = "rsvd", rsvd_oversample = 10L,
    rsvd_power = 2L, seed = 99L, fit = TRUE
  )
  expect_identical(deployable$diagnostics$solver, "rsvd")
  expect_identical(deployable$diagnostics$rsvd$oversample, 10L)
  expect_identical(deployable$diagnostics$rsvd$power, 2L)
})
