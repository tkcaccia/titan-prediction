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
variant_class_audit <- list()
coverage_audit <- list()
eligibility_audit <- list()
protein_altering_classes <- c(
  "Missense_Mutation", "Nonsense_Mutation", "Nonstop_Mutation",
  "Splice_Site", "Translation_Start_Site", "Frame_Shift_Del",
  "Frame_Shift_Ins", "In_Frame_Del", "In_Frame_Ins"
)
for (ct in sort(unique(meta$tumor_type))) {
  genes <- drivers[cancer == ct, gene]
  if (!length(genes)) next
  maf <- tcga_load(study = ct, source = "MC3")
  variants <- as.data.table(maf@data)
  sample_type_audit[[ct]] <- variants[, .N, by = .(
    sample_type = substr(Tumor_Sample_Barcode, 14, 15)
  )][, tumor_type := ct]
  variant_class_audit[[ct]] <- variants[
    FILTER == "PASS" & substr(Tumor_Sample_Barcode, 14, 15) == "01",
    .N, by = Variant_Classification
  ][, `:=`(
    tumor_type = ct,
    retained_as_protein_altering = Variant_Classification %chin%
      protein_altering_classes
  )]
  variants <- variants[
    FILTER == "PASS" & substr(Tumor_Sample_Barcode, 14, 15) == "01" &
      Variant_Classification %chin% protein_altering_classes
  ]
  variants[, patient := substr(Tumor_Sample_Barcode, 1, 12)]
  variants <- unique(variants[Hugo_Symbol %chin% genes, .(patient, gene = Hugo_Symbol)])

  # MC3 clinical metadata, rather than the TITAN cohort, defines which primary
  # tumour specimens were actually mutation-profiled. Only matched profiled
  # patients may be assigned wild type. Patients absent from this denominator
  # remain missing and never enter mutation classification.
  clinical <- as.data.table(maf@clinical.data)
  barcode_column <- if ("Tumor_Sample_Barcode" %in% names(clinical)) {
    "Tumor_Sample_Barcode"
  } else if ("Tumor_Sample_Barcode_min" %in% names(clinical)) {
    "Tumor_Sample_Barcode_min"
  } else {
    stop("No MC3 sample barcode column in clinical metadata for ", ct)
  }
  primary_samples <- unique(as.character(clinical[[barcode_column]]))
  primary_samples <- primary_samples[
    !is.na(primary_samples) & nzchar(primary_samples) &
      substr(primary_samples, 14, 15) == "01"
  ]
  profiled_patients <- substr(primary_samples, 1, 12)
  titan_patients <- meta[tumor_type == ct, patient]
  patients <- intersect(titan_patients, unique(profiled_patients))
  if (!length(patients)) next

  primary_sample_counts <- table(profiled_patients)
  coverage_audit[[ct]] <- data.table(
    tumor_type = ct,
    titan_embedding_patients = length(titan_patients),
    mc3_primary_samples = length(primary_samples),
    mc3_primary_patients = uniqueN(profiled_patients),
    matched_profiled_patients = length(patients),
    embedding_patients_without_mc3_profile =
      length(setdiff(titan_patients, profiled_patients)),
    profiled_patients_with_multiple_primary_aliquots =
      sum(primary_sample_counts > 1L),
    maximum_primary_aliquots = max(primary_sample_counts),
    wild_type_rule = paste(
      "matched MC3-profiled primary-tumour patient with no qualifying",
      "PASS protein-altering variant in the gene"
    )
  )

  counts <- variants[patient %chin% patients,
                     .(positive = uniqueN(patient)), by = gene]
  counts <- merge(data.table(gene = genes), counts, by = "gene", all.x = TRUE)
  counts[is.na(positive), positive := 0L]
  counts[, `:=`(
    negative = length(patients) - positive,
    n_profiled = length(patients),
    tumor_type = ct
  )]
  counts[, eligibility := fifelse(
    positive < cfg$analysis$binary_min_positive, "insufficient_positive",
    fifelse(negative < cfg$analysis$binary_min_negative,
            "insufficient_negative", "eligible")
  )]
  eligibility_audit[[ct]] <- counts
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
fwrite(rbindlist(variant_class_audit),
       "results/tables/mutation_variant_classification_audit.csv")
fwrite(rbindlist(coverage_audit, use.names = TRUE, fill = TRUE),
       "results/tables/mutation_coverage_audit.csv")
fwrite(rbindlist(eligibility_audit, use.names = TRUE, fill = TRUE),
       "results/tables/mutation_target_eligibility_audit.csv")
cat("eligible cancer-gene targets:", nrow(catalog), "\n")
