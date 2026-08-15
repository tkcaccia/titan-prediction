suppressPackageStartupMessages(library(data.table))
source("R/utils.R")
cfg <- load_project_config()

studies <- c(
  "acc", "blca", "brca", "cesc", "chol", "coadread", "dlbc", "esca",
  "gbm", "hnsc", "kich", "kirc", "kirp", "lgg", "lihc", "luad",
  "lusc", "meso", "ov", "paad", "pcpg", "prad", "sarc", "skcm",
  "stad", "tgct", "thca", "thym", "ucec", "ucs", "uvm"
)

dir.create("data/external/cbioportal", recursive = TRUE, showWarnings = FALSE)
base <- paste0(
  "https://media.githubusercontent.com/media/cBioPortal/datahub/master/public/",
  "%s_tcga_pan_can_atlas_2018/data_clinical_sample.txt"
)

manifest <- vector("list", length(studies))
for (i in seq_along(studies)) {
  study <- studies[i]
  url <- sprintf(base, study)
  dest <- file.path("data/external/cbioportal", paste0(study, "_clinical_sample.txt"))
  download.file(url, destfile = dest, mode = "wb", quiet = FALSE)
  manifest[[i]] <- data.table(
    study = study,
    url = url,
    file = dest,
    bytes = file.info(dest)$size,
    sha256 = digest::digest(file = dest, algo = "sha256")
  )
}
fwrite(rbindlist(manifest), "results/tables/cbioportal_download_manifest.csv")

