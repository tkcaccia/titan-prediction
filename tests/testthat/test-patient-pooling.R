test_that("mean pooling is patient-level and order invariant", {
  X <- matrix(c(1, 3, 2, 4, 8, 10), ncol = 2, byrow = TRUE)
  patient <- c("A", "A", "B")
  pool <- function(X, patient) {
    ids <- unique(patient)
    g <- match(patient, ids)
    out <- rowsum(X, g, reorder = FALSE) / tabulate(g, nbins = length(ids))
    rownames(out) <- ids
    out
  }
  a <- pool(X, patient)
  ord <- c(3, 2, 1)
  b <- pool(X[ord, , drop = FALSE], patient[ord])
  expect_equal(a[sort(rownames(a)), ], b[sort(rownames(b)), ])
  expect_equal(unname(a["A", ]), c(1.5, 3.5))
})

test_that("nested folds assign every observation exactly once", {
  source(file.path("..", "..", "R", "utils.R"))
  y <- factor(rep(c("0", "1"), each = 25))
  fold <- stratified_folds(y, 5, 42)
  expect_equal(sort(unique(fold)), 1:5)
  expect_true(all(table(fold, y) > 0))
})
