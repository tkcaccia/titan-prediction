.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
library(testthat)
test_dir("tests/testthat")
