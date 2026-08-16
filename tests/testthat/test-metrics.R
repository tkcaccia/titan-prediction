source(file.path("..", "..", "R", "utils.R"))

test_that("balanced accuracy and rank AUC have known values", {
  truth <- factor(c(0, 0, 1, 1), levels = c(0, 1))
  expect_equal(balanced_accuracy(truth, factor(c(0, 1, 1, 1), levels = c(0, 1))),
               0.75)
  expect_equal(rank_auc(truth, c(0.1, 0.2, 0.8, 0.9)), 1)
})

test_that("binary metric bundle reports sensitivity, specificity and AUROC", {
  truth <- factor(c(0, 0, 0, 1, 1, 1), levels = c(0, 1))
  estimate <- factor(c(0, 0, 1, 0, 1, 1), levels = c(0, 1))
  metrics <- binary_classification_metrics(
    truth, estimate, c(-3, -2, -1, 1, 2, 3)
  )
  expect_equal(metrics$sensitivity, 2 / 3)
  expect_equal(metrics$specificity, 2 / 3)
  expect_equal(metrics$balanced_accuracy, 2 / 3)
  expect_equal(metrics$auc, 1)
})

test_that("Q-squared is one for perfect predictions", {
  expect_equal(q_squared(1:5, 1:5), 1)
})

test_that("continuous endpoint transformations are centrally defined", {
  expect_equal(
    continuous_endpoint_transform(
      c("thorsson", "thorsson", "fusion", "aneuploidy"),
      c("Nonsilent Mutation Rate", "Leukocyte Fraction", "Fusion burden",
        "Aneuploidy score")
    ),
    c("log1p", "none", "log1p", "none")
  )
})

test_that("repeated binary metrics do not pool incomparable LDA score scales", {
  d <- data.table::data.table(
    `repeat` = rep(1:2, each = 4),
    observed = rep(c(0L, 0L, 1L, 1L), 2),
    predicted = rep(c(0L, 0L, 1L, 1L), 2),
    lda_score = c(0, 1, 2, 3, 100, 101, 102, 103)
  )
  metrics <- mean_repeat_binary_metrics(d)
  expect_equal(metrics$sensitivity, 1)
  expect_equal(metrics$specificity, 1)
  expect_equal(metrics$balanced_accuracy, 1)
  expect_equal(metrics$auc, 1)
  expect_lt(
    rank_auc(factor(d$observed, levels = c(0L, 1L)), d$lda_score),
    1
  )
})
