suppressPackageStartupMessages({
  library(data.table)
  library(readxl)
})
source("R/utils.R")
cfg <- load_project_config()
assert_files(cfg$paths[c("titan_features", "slide_reports", "thorsson")])

titan <- fread(cfg$paths$titan_features)
feature_names <- grep(cfg$analysis$feature_pattern, names(titan), value = TRUE)
stopifnot(length(feature_names) == cfg$analysis$expected_features)
titan[, patient := substr(filename, 1, 12)]
titan[, sample_type := substr(filename, 14, 15)]
titan <- titan[sample_type == "01" & grepl("-DX", filename)]
stopifnot(!anyDuplicated(titan$filename))

patient_order <- unique(titan$patient)
group <- match(titan$patient, patient_order)
X_slide <- as.matrix(titan[, ..feature_names])
X_sum <- rowsum(X_slide, group = group, reorder = FALSE)
n_slides <- tabulate(group, nbins = length(patient_order))
X_patient <- X_sum / n_slides
rownames(X_patient) <- patient_order
colnames(X_patient) <- feature_names

slide_index <- titan[, .(
  slide_ids = paste(sort(filename), collapse = ";"),
  n_slides = .N
), by = patient]

reports <- fread(
  cfg$paths$slide_reports,
  select = c("slide_id", "submitter_id", "project_id",
             "site_of_resection_or_biopsy")
)
reports[, patient := substr(submitter_id, 1, 12)]
report_map <- reports[, .(
  report_project = if (uniqueN(project_id) == 1L) unique(project_id) else NA_character_,
  resection_site = paste(sort(unique(site_of_resection_or_biopsy)), collapse = ";"),
  report_slides = uniqueN(slide_id)
), by = patient]

th <- as.data.table(read_excel(cfg$paths$thorsson, sheet = "PanImmune_MS",
                               na = c("", "NA")))
th_map <- unique(th[, .(
  patient = `TCGA Participant Barcode`,
  thorsson_cancer = `TCGA Study`
)])

meta <- merge(slide_index, report_map, by = "patient", all.x = TRUE)
meta <- merge(meta, th_map, by = "patient", all.x = TRUE)
meta[, report_cancer := sub("^TCGA-", "", report_project)]
meta[, tumor_type := fifelse(!is.na(thorsson_cancer), thorsson_cancer, report_cancer)]
meta[, tissue_source_site := substr(patient, 6, 7)]
meta[, report_covered := !is.na(report_project)]
meta[, cohort_order := match(patient, patient_order)]
setorder(meta, cohort_order)
meta[, cohort_order := NULL]
stopifnot(identical(meta$patient, patient_order))

cohort <- list(
  X = X_patient,
  meta = meta,
  feature_names = feature_names,
  aggregation = "arithmetic mean across all primary-tumour diagnostic slides",
  source_file = normalizePath(cfg$paths$titan_features),
  source_sha256 = digest::digest(file = cfg$paths$titan_features, algo = "sha256")
)
saveRDS(cohort, "data/processed/patient_cohort.rds", compress = "xz")
fwrite(meta, "results/tables/patient_cohort_summary.csv")

summary <- meta[, .(
  patients = .N,
  slides = sum(n_slides),
  multi_slide_patients = sum(n_slides > 1),
  report_covered_patients = sum(report_covered),
  missing_cancer = sum(is.na(tumor_type))
)]
print(summary)
