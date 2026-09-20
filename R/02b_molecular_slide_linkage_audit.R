legacy_lib <- Sys.getenv("TITAN_LEGACY_RLIB", "../titan-study-restart/.Rlib")
.libPaths(c(normalizePath(".Rlib", mustWork = FALSE),
            if (dir.exists(legacy_lib)) normalizePath(legacy_lib), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(readxl)
  library(TCGAmutations)
})
source("R/utils.R")
cfg <- load_project_config()

slides <- fread(cfg$paths$titan_features, select = "filename")
slides[, `:=`(
  patient = substr(filename, 1, 12),
  sample_barcode = substr(filename, 1, 15),
  sample_type = substr(filename, 14, 15)
)]
slides <- unique(slides[sample_type == "01" & grepl("-DX", filename),
                        .(patient, sample_barcode)])
cohort_patients <- unique(slides$patient)

audit_one <- function(source, x = NULL, sample_col = NULL,
                      identifier_resolution, label_noise_note) {
  if (is.null(sample_col)) {
    covered <- intersect(cohort_patients, unique(as.character(x$patient)))
    return(data.table(
      source = source,
      identifier_resolution = identifier_resolution,
      covered_patients = length(covered),
      patients_with_sample_barcode = 0L,
      exact_slide_sample_patients = NA_integer_,
      participant_only_or_nonmatching_patients = length(covered),
      exact_percent_all_covered = NA_real_,
      exact_percent_resolvable = NA_real_,
      patients_with_multiple_molecular_primary_samples = NA_integer_,
      maximum_molecular_primary_samples = NA_integer_,
      label_noise_note = label_noise_note
    ))
  }
  z <- unique(x[, .(
    patient = substr(as.character(get(sample_col)), 1, 12),
    molecular_sample = substr(as.character(get(sample_col)), 1, 15)
  )])
  z <- z[patient %chin% cohort_patients & substr(molecular_sample, 14, 15) == "01"]
  per_patient <- z[, .(
    molecular_primary_samples = uniqueN(molecular_sample),
    exact_slide_sample = any(molecular_sample %chin%
      slides[.BY$patient, on = "patient", sample_barcode])
  ), by = patient]
  data.table(
    source = source,
    identifier_resolution = identifier_resolution,
    covered_patients = nrow(per_patient),
    patients_with_sample_barcode = nrow(per_patient),
    exact_slide_sample_patients = sum(per_patient$exact_slide_sample),
    participant_only_or_nonmatching_patients = sum(!per_patient$exact_slide_sample),
    exact_percent_all_covered = 100 * mean(per_patient$exact_slide_sample),
    exact_percent_resolvable = 100 * mean(per_patient$exact_slide_sample),
    patients_with_multiple_molecular_primary_samples =
      sum(per_patient$molecular_primary_samples > 1L),
    maximum_molecular_primary_samples = max(per_patient$molecular_primary_samples),
    label_noise_note = label_noise_note
  )
}

out <- list()
th <- as.data.table(read_excel(cfg$paths$thorsson, sheet = "PanImmune_MS",
                               na = c("", "NA")))
th <- th[, .(patient = as.character(`TCGA Participant Barcode`))]
out[[length(out) + 1L]] <- audit_one(
  "Thorsson2018_PanImmune_MS", th, NULL, "participant identifier only",
  paste("No sample, portion, analyte or aliquot identifier is supplied;",
        "every matched label is participant-level and may refer to a different tumour block."))

ane <- as.data.table(read_excel(cfg$paths$aneuploidy, skip = 1))
out[[length(out) + 1L]] <- audit_one(
  "Taylor2018_TableS2", ane, "Sample", "TCGA sample barcode available",
  paste("A 15-character TCGA sample match identifies the same primary-tumour specimen,",
        "but does not prove that the WSI and molecular assay used the same portion, analyte, aliquot or block."))

onc <- as.data.table(read_excel(cfg$paths$oncogenic, sheet = "Pathway level",
                                na = c("", "NA")))
out[[length(out) + 1L]] <- audit_one(
  "SanchezVega2018_TableS4", onc, "SAMPLE_BARCODE", "TCGA sample barcode available",
  paste("Pathway calls can be linked at sample level; portion-, analyte-, aliquot- and",
        "block-level identity is unavailable and multiple primary samples are collapsed by patient."))

fus <- as.data.table(read_excel(cfg$paths$fusion,
                                sheet = "TCGA samples used in this study", skip = 1))
out[[length(out) + 1L]] <- audit_one(
  "Gao2018_TableS1", fus, "Sample", "TCGA sample barcode available",
  paste("The assay denominator is sample-indexed, but RNA aliquot/block identity and",
        "within-tumour fusion heterogeneity cannot be resolved from the released table."))

msi_files <- list.files("data/external/cbioportal",
                        pattern = "_clinical_sample\\.txt$", full.names = TRUE)
msi <- rbindlist(lapply(msi_files, function(f) {
  z <- fread(f, skip = 4, na.strings = c("NA", ""))
  z[, .(SAMPLE_ID)]
}), fill = TRUE)
out[[length(out) + 1L]] <- audit_one(
  "cBioPortal_TCGA_PanCancer", msi, "SAMPLE_ID", "TCGA sample barcode available",
  paste("MSI scores can be linked at sample level, but the released clinical files do not",
        "establish the same molecular aliquot, slide block or tumour region."))

mutation_samples <- list()
for (ct in sort(unique(na.omit(readRDS("data/processed/patient_cohort.rds")$meta$tumor_type)))) {
  maf <- try(TCGAmutations::tcga_load(study = ct, source = "MC3"), silent = TRUE)
  if (inherits(maf, "try-error")) next
  clinical <- as.data.table(maf@clinical.data)
  bc <- intersect(c("Tumor_Sample_Barcode", "Tumor_Sample_Barcode_min"), names(clinical))[1]
  if (!is.na(bc)) mutation_samples[[ct]] <- clinical[, .(sample = as.character(get(bc)))]
}
mutation_samples <- rbindlist(mutation_samples, fill = TRUE)
out[[length(out) + 1L]] <- audit_one(
  "TCGA_MC3_Bailey2018", mutation_samples, "sample", "TCGA sample barcode available",
  paste("MC3 profiling status and mutation calls are sample-indexed; a sample match does not",
        "guarantee the same portion, analyte, aliquot, block or subclone as the diagnostic WSI."))

audit <- rbindlist(out, fill = TRUE)
audit[, linkage_unit := "unique embedding-cohort patient covered by the molecular source"]
setcolorder(audit, c(
  "source", "linkage_unit", "identifier_resolution", "covered_patients",
  "patients_with_sample_barcode", "exact_slide_sample_patients",
  "participant_only_or_nonmatching_patients", "exact_percent_all_covered",
  "exact_percent_resolvable", "patients_with_multiple_molecular_primary_samples",
  "maximum_molecular_primary_samples", "label_noise_note"
))
fwrite(audit, "results/tables/molecular_slide_linkage_audit.csv")
print(audit)
