project_lib <- normalizePath(".Rlib", mustWork = FALSE)
legacy_lib <- Sys.getenv("TITAN_LEGACY_RLIB", "../titan-study-restart/.Rlib")
.libPaths(c(project_lib,
            if (dir.exists(legacy_lib)) normalizePath(legacy_lib),
            .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
})
source("R/utils.R")
cfg <- load_project_config()

labels <- c(
  titan_features = "Ding et al. 2025 TITAN TCGA embeddings",
  slide_reports = "Ding et al. 2025 TCGA slide reports",
  thorsson = "Thorsson et al. 2018 PanImmune_MS",
  tcga_cdr = "Liu et al. 2018 TCGA Clinical Data Resource",
  bailey = "Bailey et al. 2018 Table S1",
  aneuploidy = "Taylor et al. 2018 Table S2",
  oncogenic = "Sanchez-Vega et al. 2018 Table S4",
  fusion = "Gao et al. 2018 Table S1",
  msi_subset = "Bonneville et al. 2017 ACC/CESC/MESO subset"
)
dois <- c(
  titan_features = "10.1038/s41591-025-03982-3",
  slide_reports = "10.1038/s41591-025-03982-3",
  thorsson = "10.1016/j.immuni.2018.03.023",
  tcga_cdr = "10.1016/j.cell.2018.02.052",
  bailey = "10.1016/j.cell.2018.02.060",
  aneuploidy = "10.1016/j.ccell.2018.03.007",
  oncogenic = "10.1016/j.cell.2018.03.035",
  fusion = "10.1016/j.celrep.2018.03.050",
  msi_subset = "10.1200/PO.17.00073"
)

manifest <- rbindlist(lapply(names(cfg$paths), function(key) {
  path <- cfg$paths[[key]]
  data.table(
    source_key = key, label = labels[[key]], doi = dois[[key]],
    source_filename = basename(path),
    exists = file.exists(path),
    bytes = if (file.exists(path)) file.info(path)$size else NA_real_,
    sha256 = if (file.exists(path)) digest::digest(file = path, algo = "sha256")
      else NA_character_
  )
}))
fwrite(manifest, "results/tables/source_manifest.csv")

software_packages <- c(
  "data.table", "digest", "fastPLS", "future.apply", "ggplot2",
  "jsonlite", "maftools", "pROC", "readxl", "TCGAmutations", "testthat"
)
configured_source <- c(
  fastPLS = "tkcaccia/fastPLS@dcf45cccee8a1cb1a3ae8b3353a410ab0902162f",
  TCGAmutations = paste0(
    "PoisonAlien/TCGAmutations@",
    "3474e3412cfa1490db4a84db57e4a732480990a9"
  )
)
software <- rbindlist(lapply(software_packages, function(package) {
  installed <- requireNamespace(package, quietly = TRUE)
  description <- if (installed) packageDescription(package) else NULL
  data.table(
    package = package,
    installed = installed,
    version = if (installed) as.character(packageVersion(package)) else NA_character_,
    installed_remote_sha = if (installed && !is.null(description$RemoteSha))
      as.character(description$RemoteSha) else NA_character_,
    configured_source = if (package %chin% names(configured_source))
      configured_source[[package]] else NA_character_
  )
}))
software <- rbindlist(list(
  data.table(
    package = "R", installed = TRUE,
    version = paste(R.version$major, R.version$minor, sep = "."),
    installed_remote_sha = NA_character_, configured_source = R.version$platform
  ),
  software
), use.names = TRUE)
fwrite(software, "results/tables/software_manifest.csv")

fastpls_description <- packageDescription("fastPLS")
session <- c(
  paste0("Analysis backend: ",
         tolower(Sys.getenv("TITAN_BACKEND", "cpu"))),
  paste0("PLS SVD method: ", cfg$analysis$svd_method),
  paste0("rSVD oversampling: ", cfg$analysis$rsvd_oversample),
  paste0("rSVD power iterations: ", cfg$analysis$rsvd_power),
  paste0("fastPLS version: ", as.character(packageVersion("fastPLS"))),
  paste0("fastPLS remote SHA: ", fastpls_description$RemoteSha),
  "",
  "Pinned analysis packages:",
  paste0(software$package, " ", software$version,
         fifelse(is.na(software$configured_source), "",
                 paste0(" [", software$configured_source, "]"))),
  "",
  sub("[[:space:]]+$", "", capture.output(sessionInfo()))
)
writeLines(session, "provenance/software_session.txt")
