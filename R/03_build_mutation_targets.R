project_lib <- normalizePath(".Rlib", mustWork = FALSE)
legacy_lib <- Sys.getenv("TITAN_LEGACY_RLIB", "../titan-study-restart/.Rlib")
.libPaths(c(project_lib, if (dir.exists(legacy_lib)) normalizePath(legacy_lib),
            .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(readxl)
  library(TCGAmutations)
  library(maftools)
})
source("R/utils.R")
cfg <- load_project_config()
cohort <- readRDS("data/processed/patient_cohort.rds")
meta <- as.data.table(cohort$meta)[!is.na(tumor_type), .(patient, tumor_type)]

# Tissue-specific driver catalogue from Bailey et al. Table S1.
raw <- read_excel(cfg$paths$bailey, sheet = "Table S1", col_names = FALSE)
header <- which(raw[[1]] == "Gene")[1]
drivers <- data.table(
  gene = raw[[1]][(header + 1L):nrow(raw)],
  cancer = raw[[2]][(header + 1L):nrow(raw)]
)
drivers <- unique(drivers[!is.na(gene) & !is.na(cancer) & cancer != "PANCAN"])
coadread <- drivers[cancer == "COADREAD"]
drivers <- drivers[cancer != "COADREAD"]
drivers <- unique(rbind(
  drivers,
  coadread[, .(gene, cancer = "COAD")],
  coadread[, .(gene, cancer = "READ")]
))
fwrite(drivers, "results/tables/bailey_tissue_specific_drivers.csv")

out <- list()
sample_type_audit <- list()
for (ct in sort(unique(meta$tumor_type))) {
  genes <- drivers[cancer == ct, gene]
  if (!length(genes)) next
  maf <- tcga_load(study = ct, source = "MC3")
  variants <- as.data.table(maf@data)
  sample_type_audit[[ct]] <- variants[, .N, by = .(
    sample_type = substr(Tumor_Sample_Barcode, 14, 15)
  )][, tumor_type := ct]
  variants <- variants[
    FILTER == "PASS" & substr(Tumor_Sample_Barcode, 14, 15) == "01"
  ]
  variants[, patient := substr(Tumor_Sample_Barcode, 1, 12)]
  variants <- unique(variants[Hugo_Symbol %chin% genes, .(patient, gene = Hugo_Symbol)])
  patients <- meta[tumor_type == ct, patient]
  counts <- variants[patient %chin% patients, .(positive = uniqueN(patient)), by = gene]
  counts[, negative := length(patients) - positive]
  eligible <- counts[
    positive >= cfg$analysis$binary_min_positive &
      negative >= cfg$analysis$binary_min_negative
  ]
  if (!nrow(eligible)) next
  for (gene_i in eligible$gene) {
    d <- data.table(patient = patients, tumor_type = ct, endpoint = gene_i)
    d[, value := as.integer(patient %chin% variants[gene == gene_i, patient])]
    d[, `:=`(
      family = "driver_mutation", subfamily = "Bailey_tissue_specific_driver",
      outcome_type = "binary", source = "TCGA_MC3_Bailey2018"
    )]
    out[[length(out) + 1L]] <- d
  }
}

mutation_dt <- rbindlist(out, use.names = TRUE)
setcolorder(mutation_dt, c("patient", "tumor_type", "family", "subfamily",
                           "endpoint", "outcome_type", "value", "source"))
saveRDS(mutation_dt, "data/processed/binary_targets_mutation.rds", compress = "xz")

catalog <- mutation_dt[, .(
  n = .N, positive = sum(value == 1L), negative = sum(value == 0L),
  prevalence = mean(value == 1L)
), by = .(family, subfamily, endpoint, tumor_type, source)]
fwrite(catalog, "results/tables/binary_target_catalog_mutation.csv")
fwrite(rbindlist(sample_type_audit),
       "results/tables/mutation_sample_type_audit.csv")
cat("eligible cancer-gene targets:", nrow(catalog), "\n")
