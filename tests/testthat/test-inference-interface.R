test_that("exported continuous and binary models predict every patient", {
  skip_if_not_installed("fastPLS")
  old <- getwd()
  on.exit(setwd(old), add = TRUE)
  root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
  setwd(root)
  source("R/utils.R")
  source("examples/predict_titan_features.R")
  set.seed(108)
  X <- matrix(rnorm(80 * 20), 80, 20)
  colnames(X) <- sprintf("titan_%03d", seq_len(ncol(X)) - 1L)
  cfg <- load_project_config()$analysis

  y <- X[, 1] - X[, 2] + rnorm(80)
  cm <- fit_final_model(X, y, "continuous", 2L, cfg, 108)
  cf <- tempfile(fileext = ".rds")
  saveRDS(list(model = cm, outcome_type = "continuous",
               feature_names = colnames(X)), cf)
  cp <- predict_titan_model(cf, as.data.frame(X[1:4, ]),
                            patient_id = paste0("P", seq_len(4)))
  expect_equal(nrow(cp), 4L)
  expect_true(all(is.finite(cp$prediction)))

  yb <- factor(as.integer(X[, 1] + rnorm(80) > 0), levels = c(0, 1))
  bm <- fit_final_model(X, yb, "binary", 2L, cfg, 109)
  bf <- tempfile(fileext = ".rds")
  saveRDS(list(model = bm, outcome_type = "binary",
               feature_names = colnames(X)), bf)
  bp <- predict_titan_model(bf, as.data.frame(X[1:4, ]),
                            patient_id = paste0("P", seq_len(4)))
  expect_equal(nrow(bp), 4L)
  expect_true(all(is.finite(bp$lda_score)))
})
