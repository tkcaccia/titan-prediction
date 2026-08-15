suppressPackageStartupMessages(library(data.table))
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

session <- capture.output(sessionInfo())
writeLines(session, "provenance/software_session.txt")
