source(file.path("..", "..", "R", "utils.R"))

test_that("balanced accuracy and rank AUC have known values", {
  truth <- factor(c(0, 0, 1, 1), levels = c(0, 1))
  expect_equal(balanced_accuracy(truth, factor(c(0, 1, 1, 1), levels = c(0, 1))),
               0.75)
  expect_equal(rank_auc(truth, c(0.1, 0.2, 0.8, 0.9)), 1)
})

test_that("Q-squared is one for perfect predictions", {
  expect_equal(q_squared(1:5, 1:5), 1)
})
