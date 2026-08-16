suppressPackageStartupMessages({
  library(data.table)
  library(readxl)
})
source("R/utils.R")
cfg <- load_project_config()
assert_files(cfg$paths[c("thorsson", "aneuploidy", "oncogenic", "fusion",
                         "msi_subset")])
cohort <- readRDS("data/processed/patient_cohort.rds")
meta <- as.data.table(cohort$meta)[, .(patient, tumor_type)]

continuous <- list()
binary <- list()
sample_type_audit <- list()
coverage_audit <- list()

record_source_coverage <- function(source, primary_rows, covered_patients,
                                   aggregation_rule,
                                   sample_column = NULL) {
  z <- copy(primary_rows)
  if (!"patient" %in% names(z)) stop("primary_rows must contain patient")
  if (is.null(sample_column) || !sample_column %in% names(z)) {
    z[, source_sample := patient]
  } else {
    z[, source_sample := as.character(get(sample_column))]
  }
  per_patient <- z[, .(
    primary_aliquots = uniqueN(source_sample)
  ), by = patient]
  d <- merge(meta, per_patient, by = "patient", all.x = TRUE)
  d[, covered := patient %chin% unique(covered_patients)]
  coverage_audit[[length(coverage_audit) + 1L]] <<- d[, .(
    cohort_patients = .N,
    covered_patients = sum(covered),
    missing_patients = sum(!covered),
    covered_primary_aliquots = sum(primary_aliquots[covered], na.rm = TRUE),
    patients_with_multiple_primary_aliquots =
      sum(primary_aliquots > 1L, na.rm = TRUE),
    maximum_primary_aliquots = if (any(covered))
      max(primary_aliquots[covered], na.rm = TRUE) else 0L
  ), by = tumor_type][, `:=`(
    source = source,
    aggregation_rule = aggregation_rule
  )]
}

append_continuous <- function(d, family, source, endpoints, transform = NULL,
                              subfamily = family) {
  z <- melt(d, id.vars = c("patient", "tumor_type"),
            measure.vars = endpoints, variable.name = "endpoint",
            value.name = "value", variable.factor = FALSE)
  z[, value := as.numeric(value)]
  if (!is.null(transform)) z[, value := transform(value, endpoint)]
  z <- z[is.finite(value)]
  z[, `:=`(family = family, subfamily = subfamily, source = source,
           outcome_type = "continuous")]
  continuous[[length(continuous) + 1L]] <<- z
}

append_binary <- function(d, family, source, endpoints,
                          subfamily = family) {
  z <- melt(d, id.vars = c("patient", "tumor_type"),
            measure.vars = endpoints, variable.name = "endpoint",
            value.name = "value", variable.factor = FALSE)
  z[, value := as.integer(value)]
  z <- z[value %in% c(0L, 1L)]
  z[, `:=`(family = family, subfamily = subfamily, source = source,
           outcome_type = "binary")]
  binary[[length(binary) + 1L]] <<- z
}

# Thorsson et al. PanImmune_MS: the 50 non-survival, non-aggregate scores.
th <- as.data.table(read_excel(cfg$paths$thorsson, sheet = "PanImmune_MS",
                               na = c("", "NA")))
meta_cols <- c("TCGA Participant Barcode", "TCGA Study", "Immune Subtype",
               "TCGA Subtype", "OS", "OS Time", "PFI", "PFI Time")
score_cols <- setdiff(names(th)[seq_len(ncol(th) - 6L)], meta_cols)
th <- th[, c("TCGA Participant Barcode", score_cols), with = FALSE]
setnames(th, "TCGA Participant Barcode", "patient")
setnames(th, names(th), sub("\\.\\.\\..*$", "", names(th)))
score_cols <- sub("\\.\\.\\..*$", "", score_cols)
th <- merge(meta, th, by = "patient")
record_source_coverage(
  "Thorsson2018_PanImmune_MS",
  th[, .(patient)], th$patient,
  "one participant-level row; endpoint-specific missing values retained"
)
append_continuous(
  th, "thorsson", "Thorsson2018_PanImmune_MS", score_cols,
  transform = function(value, endpoint) {
    idx <- continuous_endpoint_transform("thorsson", endpoint) == "log1p"
    value[idx] <- log1p(value[idx])
    value
  },
  subfamily = "immune_inflammatory_and_genomic_context"
)

# Taylor et al. aneuploidy endpoints.
ane <- as.data.table(read_excel(cfg$paths$aneuploidy, skip = 1))
sample_type_audit[["aneuploidy"]] <- ane[, .N, by = .(
  sample_type = substr(Sample, 14, 15)
)][, source := "aneuploidy"]
ane <- ane[substr(Sample, 14, 15) == "01"]
ane[, patient := substr(Sample, 1, 12)]
ane_primary <- copy(ane)
ane <- merge(meta, ane, by = "patient")
setnames(ane,
         c("AneuploidyScore(AS)", "AS_del", "AS_amp", "Genome_doublings"),
         c("Aneuploidy score", "Deleted arm count", "Amplified arm count",
           "Genome doubling"))
ane_patient <- ane[, .(
  `Aneuploidy score` = mean(as.numeric(`Aneuploidy score`), na.rm = TRUE),
  `Deleted arm count` = mean(as.numeric(`Deleted arm count`), na.rm = TRUE),
  `Amplified arm count` = mean(as.numeric(`Amplified arm count`), na.rm = TRUE),
  `Genome doubling` = {
    values <- as.numeric(`Genome doubling`)
    if (all(!is.finite(values))) NA_integer_ else
      as.integer(any(values > 0, na.rm = TRUE))
  }
), by = .(patient, tumor_type)]
record_source_coverage(
  "Taylor2018_TableS2", ane_primary, ane_patient$patient,
  "mean across primary aliquots for continuous burdens; any positive aliquot for genome doubling",
  "Sample"
)
append_continuous(ane_patient, "aneuploidy", "Taylor2018_TableS2",
                  c("Aneuploidy score", "Deleted arm count",
                    "Amplified arm count"))
append_binary(ane_patient, "aneuploidy", "Taylor2018_TableS2",
              "Genome doubling")

# Sanchez-Vega et al. pathway-level binary genomic alteration matrix.
onc <- as.data.table(read_excel(cfg$paths$oncogenic, sheet = "Pathway level",
                                na = c("", "NA")))
sample_type_audit[["oncogenic_pathway"]] <- onc[, .N, by = .(
  sample_type = substr(SAMPLE_BARCODE, 14, 15)
)][, source := "oncogenic_pathway"]
onc <- onc[substr(SAMPLE_BARCODE, 14, 15) == "01"]
onc[, patient := substr(SAMPLE_BARCODE, 1, 12)]
pathways <- setdiff(names(onc), c("SAMPLE_BARCODE", "patient"))
for (j in pathways) set(onc, j = j, value = as.integer(onc[[j]]))
onc_primary <- copy(onc)
onc_patient <- onc[, lapply(.SD, function(x) {
  if (all(is.na(x))) NA_integer_ else as.integer(max(x, na.rm = TRUE))
}), by = patient, .SDcols = pathways]
onc_patient <- merge(meta, onc_patient, by = "patient")
record_source_coverage(
  "SanchezVega2018_TableS4", onc_primary, onc_patient$patient,
  "any altered primary aliquot defines patient-level pathway alteration",
  "SAMPLE_BARCODE"
)
append_binary(onc_patient, "oncogenic_pathway", "SanchezVega2018_TableS4",
              pathways)

# Gao et al. fusion calls. The study sample list defines the denominator.
fusion_samples <- as.data.table(read_excel(
  cfg$paths$fusion, sheet = "TCGA samples used in this study", skip = 1
))
fusion_calls <- as.data.table(read_excel(
  cfg$paths$fusion, sheet = "Final fusion call set", skip = 1
))
sample_type_audit[["fusion_denominator"]] <- fusion_samples[, .N, by = .(
  sample_type = substr(Sample, 14, 15)
)][, source := "fusion_denominator"]
sample_type_audit[["fusion_calls"]] <- fusion_calls[, .N, by = .(
  sample_type = substr(Sample, 14, 15)
)][, source := "fusion_calls"]
fusion_samples <- fusion_samples[substr(Sample, 14, 15) == "01"]
fusion_calls <- fusion_calls[substr(Sample, 14, 15) == "01"]
fusion_samples[, patient := substr(Sample, 1, 12)]
fusion_calls[, patient := substr(Sample, 1, 12)]
fusion_samples_primary <- copy(fusion_samples)
denom <- unique(fusion_samples[, .(patient, fusion_cancer = Cancer)])
denom <- merge(meta, denom, by = "patient")
calls <- unique(fusion_calls[, .(patient, Fusion)])
burden <- calls[, .(fusion_burden = uniqueN(Fusion)), by = patient]
fusion_patient <- merge(denom, burden, by = "patient", all.x = TRUE)
fusion_patient[is.na(fusion_burden), fusion_burden := 0L]
fusion_patient[, `Any called fusion` := as.integer(fusion_burden > 0)]
fusion_patient[, `Fusion burden` := log1p(fusion_burden)]
record_source_coverage(
  "Gao2018_TableS1", fusion_samples_primary, fusion_patient$patient,
  "study sample list defines assay coverage; no call within covered samples is zero; calls collapsed by unique fusion",
  "Sample"
)
append_continuous(fusion_patient, "fusion", "Gao2018_TableS1",
                  "Fusion burden")
append_binary(fusion_patient, "fusion", "Gao2018_TableS1",
              "Any called fusion")

pair_counts <- merge(calls, denom[, .(patient, tumor_type)], by = "patient")
pair_counts <- pair_counts[, .(positive = uniqueN(patient)),
                           by = .(tumor_type, Fusion)]
pair_n <- denom[, .(n = uniqueN(patient)), by = tumor_type]
pair_counts <- merge(pair_counts, pair_n, by = "tumor_type")
eligible_pairs <- pair_counts[positive >= cfg$analysis$binary_min_positive &
                                n - positive >= cfg$analysis$binary_min_negative]
for (i in seq_len(nrow(eligible_pairs))) {
  ct <- eligible_pairs$tumor_type[i]
  fusion <- eligible_pairs$Fusion[i]
  d <- denom[tumor_type == ct, .(patient, tumor_type)]
  positive_patients <- calls[Fusion == fusion, patient]
  d[, value := as.integer(patient %chin% positive_patients)]
  d[, endpoint := paste0("Fusion pair: ", fusion)]
  d[, `:=`(family = "fusion", subfamily = "recurrent_fusion_pair",
           source = "Gao2018_TableS1", outcome_type = "binary")]
  binary[[length(binary) + 1L]] <- d
}

# Full pan-cancer MSI fields from cBioPortal's TCGA PanCancer Atlas studies.
msi_files <- list.files("data/external/cbioportal",
                        pattern = "_clinical_sample\\.txt$", full.names = TRUE)
if (!length(msi_files)) stop("Run R/00_download_cbioportal.R first.")
msi <- rbindlist(lapply(msi_files, function(f) {
  z <- fread(f, skip = 4, na.strings = c("NA", ""))
  keep <- intersect(c("PATIENT_ID", "SAMPLE_ID", "MSI_SCORE_MANTIS",
                      "MSI_SENSOR_SCORE"), names(z))
  z[, ..keep]
}), fill = TRUE)
msi[, patient := substr(PATIENT_ID, 1, 12)]
msi <- msi[substr(SAMPLE_ID, 14, 15) == "01"]
msi_primary <- copy(msi)
msi <- msi[, .(
  `MANTIS score` = mean(as.numeric(MSI_SCORE_MANTIS), na.rm = TRUE),
  `MSIsensor score` = mean(as.numeric(MSI_SENSOR_SCORE), na.rm = TRUE)
), by = patient]
for (j in c("MANTIS score", "MSIsensor score")) {
  set(msi, which(!is.finite(msi[[j]])), j, NA_real_)
}
msi <- merge(meta, msi, by = "patient")
record_source_coverage(
  "cBioPortal_TCGA_PanCancer", msi_primary,
  msi[is.finite(`MANTIS score`) | is.finite(`MSIsensor score`), patient],
  "mean of finite primary-aliquot scores; patient is missing when all primary-aliquot scores are missing",
  "SAMPLE_ID"
)
append_continuous(msi, "microsatellite_instability", "cBioPortal_TCGA_PanCancer",
                  c("MANTIS score", "MSIsensor score"))

# Binary definition matching Bonneville et al.: MANTIS >0.4 versus <=0.4.
msi[, `MSI-H (MANTIS >0.4)` := fifelse(
  is.na(`MANTIS score`), NA_integer_, as.integer(`MANTIS score` > 0.4)
)]
append_binary(msi, "microsatellite_instability", "Bonneville2017_cBioPortal",
              "MSI-H (MANTIS >0.4)")

# Sensitivity definition documented by the current cBioPortal clinical files:
# >0.6 MSI-H, <0.4 MSS, with 0.4-0.6 excluded as indeterminate.
msi[, `MSI-H strict (MANTIS >0.6)` := fifelse(
  `MANTIS score` > 0.6, 1L,
  fifelse(`MANTIS score` < 0.4, 0L, NA_integer_)
)]
append_binary(msi, "microsatellite_instability_sensitivity",
              "cBioPortal_threshold_documentation",
              "MSI-H strict (MANTIS >0.6)")

continuous_dt <- rbindlist(continuous, use.names = TRUE, fill = TRUE)
binary_dt <- rbindlist(binary, use.names = TRUE, fill = TRUE)
setcolorder(continuous_dt, c("patient", "tumor_type", "family", "subfamily",
                             "endpoint", "outcome_type", "value", "source"))
setcolorder(binary_dt, c("patient", "tumor_type", "family", "subfamily",
                         "endpoint", "outcome_type", "value", "source"))

saveRDS(continuous_dt, "data/processed/continuous_targets.rds", compress = "xz")
saveRDS(binary_dt, "data/processed/binary_targets_nonmutation.rds", compress = "xz")

catalog_cont <- continuous_dt[, .(
  n = sum(is.finite(value)),
  mean = mean(value, na.rm = TRUE),
  sd = sd(value, na.rm = TRUE)
), by = .(family, subfamily, endpoint, tumor_type, source)]
catalog_bin <- binary_dt[, .(
  n = .N, positive = sum(value == 1L), negative = sum(value == 0L),
  prevalence = mean(value == 1L)
), by = .(family, subfamily, endpoint, tumor_type, source)]
cohort_counts <- meta[, .(cohort_patients = .N), by = tumor_type]
catalog_cont <- merge(catalog_cont, cohort_counts, by = "tumor_type", all.x = TRUE)
catalog_cont[, missing_from_embedding_cohort := cohort_patients - n]
catalog_bin <- merge(catalog_bin, cohort_counts, by = "tumor_type", all.x = TRUE)
catalog_bin[, missing_from_embedding_cohort := cohort_patients - n]
fwrite(catalog_cont, "results/tables/continuous_target_catalog.csv")
fwrite(catalog_bin, "results/tables/binary_target_catalog_nonmutation.csv")

# Audit cBioPortal MANTIS values against the supplied 480-case subset.
subset_msi <- as.data.table(read_excel(cfg$paths$msi_subset))
subset_msi[, patient := substr(`Case ID`, 1, 12)]
audit <- merge(
  subset_msi[, .(patient, supplied_mantis = as.numeric(`MANTIS Score`))],
  msi[, .(patient, cbioportal_mantis = `MANTIS score`)], by = "patient"
)
audit[, difference := supplied_mantis - cbioportal_mantis]
fwrite(audit, "results/tables/msi_source_value_audit.csv")
fwrite(rbindlist(sample_type_audit),
       "results/tables/nonmutation_sample_type_audit.csv")
coverage_dt <- rbindlist(coverage_audit, use.names = TRUE, fill = TRUE)
setcolorder(coverage_dt, c(
  "source", "tumor_type", "cohort_patients", "covered_patients",
  "missing_patients", "covered_primary_aliquots",
  "patients_with_multiple_primary_aliquots", "maximum_primary_aliquots",
  "aggregation_rule"
))
setorder(coverage_dt, source, tumor_type)
fwrite(coverage_dt, "results/tables/molecular_source_coverage_audit.csv")

cat("continuous rows:", nrow(continuous_dt), "binary rows:", nrow(binary_dt), "\n")
cat("eligible recurrent fusion pairs:\n")
print(eligible_pairs)
