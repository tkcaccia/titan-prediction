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
  cm$Ttrain <- NULL
  cm$Yfit <- NULL
  cf <- tempfile(fileext = ".rds")
  saveRDS(list(model = cm, outcome_type = "continuous",
               feature_names = colnames(X), model_id = "test_continuous",
               fastPLS_version = as.character(packageVersion("fastPLS")),
               fastPLS_remote_sha = packageDescription("fastPLS")[["RemoteSha"]],
               endpoint_transform = "log1p",
               output_units = "log1p-transformed source endpoint units"), cf)
  cp <- predict_titan_model(cf, as.data.frame(X[1:4, ]),
                            patient_id = paste0("P", seq_len(4)))
  expect_equal(nrow(cp), 4L)
  expect_true(all(is.finite(cp$prediction)))
  expect_equal(attr(cp, "endpoint_transform"), "log1p")
  expect_equal(attr(cp, "output_units"),
               "log1p-transformed source endpoint units")

  # Range checks must use the same patient-level mean pooling as training.
  # The two deliberately extreme slides average to an in-range patient vector.
  pooled_artifact <- readRDS(cf)
  pooled_artifact$training_feature_min <- rep(-0.1, ncol(X))
  pooled_artifact$training_feature_max <- rep(0.1, ncol(X))
  pooled_file <- tempfile(fileext = ".rds")
  saveRDS(pooled_artifact, pooled_file)
  opposite_slides <- rbind(rep(5, ncol(X)), rep(-5, ncol(X)))
  colnames(opposite_slides) <- colnames(X)
  expect_no_warning(
    predict_titan_model(
      pooled_file, as.data.frame(opposite_slides),
      patient_id = c("Pooled", "Pooled")
    )
  )

  incompatible <- readRDS(cf)
  incompatible$fastPLS_version <- "0.0.0"
  incompatible_file <- tempfile(fileext = ".rds")
  saveRDS(incompatible, incompatible_file)
  expect_error(
    predict_titan_model(incompatible_file, as.data.frame(X[1:4, ]),
                        patient_id = paste0("P", seq_len(4))),
    "requires fastPLS 0.0.0"
  )

  yb <- factor(as.integer(X[, 1] + rnorm(80) > 0), levels = c(0, 1))
  bm <- fit_final_model(X, yb, "binary", 2L, cfg, 109)
  bm$Ttrain <- NULL
  bm$Yfit <- NULL
  bf <- tempfile(fileext = ".rds")
  saveRDS(list(model = bm, outcome_type = "binary",
               feature_names = colnames(X), model_id = "test_binary",
               fastPLS_version = as.character(packageVersion("fastPLS")),
               fastPLS_remote_sha = packageDescription("fastPLS")[["RemoteSha"]],
               endpoint_transform = "none",
               output_units = "class label and uncalibrated LDA score"), bf)
  bp <- predict_titan_model(bf, as.data.frame(X[1:4, ]),
                            patient_id = paste0("P", seq_len(4)))
  expect_equal(nrow(bp), 4L)
  expect_true(all(is.finite(bp$lda_score)))
  expect_equal(
    as.character(bp$predicted_class),
    ifelse(bp$lda_score > 0, "1", "0")
  )
})
