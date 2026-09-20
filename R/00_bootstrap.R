options(repos = c(CRAN = "https://cloud.r-project.org"))

cran <- c(
  "data.table", "readxl", "digest", "jsonlite", "future.apply",
  "progressr", "pROC", "ggplot2", "glmnet", "testthat", "remotes",
  "BiocManager"
)
missing <- cran[!vapply(cran, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) install.packages(missing)

dir.create(".Rlib", showWarnings = FALSE)
.libPaths(c(normalizePath(".Rlib"), .libPaths()))

expected_fastpls_sha <- "b518f75285c387632c2443a0c0989d75c9dcda48"
installed_fastpls_sha <- if (requireNamespace("fastPLS", quietly = TRUE)) {
  packageDescription("fastPLS")$RemoteSha
} else {
  NULL
}
need_fastpls <- !requireNamespace("fastPLS", quietly = TRUE) ||
  packageVersion("fastPLS") != "0.3" ||
  is.null(installed_fastpls_sha) ||
  !identical(as.character(installed_fastpls_sha), expected_fastpls_sha)
if (need_fastpls) {
  remotes::install_github(
    paste0("tkcaccia/fastPLS@", expected_fastpls_sha), lib = ".Rlib",
                          upgrade = "never", dependencies = TRUE, force = TRUE)
}

if (!requireNamespace("PathoFMPred", quietly = TRUE)) {
  remotes::install_github(
    "tkcaccia/PathoFMPred",
    lib = ".Rlib", upgrade = "never", dependencies = TRUE
  )
}

bioc <- c("maftools")
missing_bioc <- bioc[!vapply(bioc, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_bioc)) {
  BiocManager::install(missing_bioc, lib = ".Rlib", ask = FALSE,
                       update = FALSE)
}
if (!requireNamespace("TCGAmutations", quietly = TRUE)) {
  remotes::install_github(
    "PoisonAlien/TCGAmutations@3474e3412cfa1490db4a84db57e4a732480990a9",
    lib = ".Rlib",
                          upgrade = "never", dependencies = FALSE,
                          force = TRUE)
}

message("fastPLS ", as.character(packageVersion("fastPLS")),
        " (", packageDescription("fastPLS")$RemoteSha, ") installed at ",
        find.package("fastPLS"))
