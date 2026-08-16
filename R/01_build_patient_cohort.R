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
titan[, sample_barcode := substr(filename, 1, 16)]
titan <- titan[sample_type == "01" & grepl("-DX", filename)]
stopifnot(!anyDuplicated(titan$filename))

patient_order <- unique(titan$patient)
group <- match(titan$patient, patient_order)
X_slide <- as.matrix(titan[, ..feature_names])
stopifnot(all(is.finite(X_slide)))
X_sum <- rowsum(X_slide, group = group, reorder = FALSE)
n_slides <- tabulate(group, nbins = length(patient_order))
X_patient <- X_sum / n_slides
rownames(X_patient) <- patient_order
colnames(X_patient) <- feature_names
stopifnot(!anyDuplicated(rownames(X_patient)),
          !anyDuplicated(colnames(X_patient)),
          all(is.finite(X_patient)))

slide_index <- titan[, .(
  slide_ids = paste(sort(filename), collapse = ";"),
  n_slides = .N,
  n_primary_sample_barcodes = uniqueN(sample_barcode)
), by = patient]

reports <- fread(
  cfg$paths$slide_reports,
  select = c("slide_id", "submitter_id", "project_id",
             "site_of_resection_or_biopsy")
)
reports[, patient := substr(submitter_id, 1, 12)]
reports[, match_key := tolower(slide_id)]
stopifnot(!anyDuplicated(reports$match_key))
selected_slide_reports <- merge(
  titan[, .(patient, filename, sample_barcode, match_key = tolower(filename))],
  reports[, .(match_key, report_slide_id = slide_id, project_id,
              site_of_resection_or_biopsy)],
  by = "match_key", all.x = TRUE
)
stopifnot(nrow(selected_slide_reports) == nrow(titan))
selected_slide_reports[, exact_report_match := !is.na(report_slide_id)]

# Only reports matched to the selected TITAN slide identifiers contribute site
# metadata. A patient-level report lookup is retained solely as a fallback for
# cancer provenance when no selected slide has an exact report row.
exact_report_map <- selected_slide_reports[exact_report_match == TRUE, .(
  exact_report_project = if (uniqueN(project_id) == 1L) unique(project_id)
    else NA_character_,
  resection_site = paste(sort(unique(na.omit(site_of_resection_or_biopsy))),
                         collapse = ";"),
  exact_report_slides = uniqueN(report_slide_id)
), by = patient]
patient_report_map <- reports[, .(
  fallback_report_project = if (uniqueN(project_id) == 1L) unique(project_id)
    else NA_character_,
  report_file_slides = uniqueN(slide_id)
), by = patient]

th <- as.data.table(read_excel(cfg$paths$thorsson, sheet = "PanImmune_MS",
                               na = c("", "NA")))
th_map <- unique(th[, .(
  patient = `TCGA Participant Barcode`,
  thorsson_cancer = `TCGA Study`
)])

meta <- merge(slide_index, exact_report_map, by = "patient", all.x = TRUE)
meta <- merge(meta, patient_report_map, by = "patient", all.x = TRUE)
meta <- merge(meta, th_map, by = "patient", all.x = TRUE)
meta[, report_project := fifelse(!is.na(exact_report_project),
                                 exact_report_project,
                                 fallback_report_project)]
meta[, report_cancer := sub("^TCGA-", "", report_project)]
meta[, tumor_type := fifelse(!is.na(thorsson_cancer), thorsson_cancer, report_cancer)]
meta[, tissue_source_site := substr(patient, 6, 7)]
meta[, exact_report_slides := fifelse(is.na(exact_report_slides), 0L,
                                      exact_report_slides)]
meta[, report_covered := exact_report_slides > 0L]
meta[, report_coverage_fraction := exact_report_slides / n_slides]
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

slide_report_audit <- merge(
  selected_slide_reports,
  meta[, .(patient, tumor_type)], by = "patient", all.x = TRUE
)[, .(
  patients = uniqueN(patient),
  eligible_slides = .N,
  exact_report_matched_slides = sum(exact_report_match),
  unmatched_slides = sum(!exact_report_match),
  patients_with_exact_report_match = uniqueN(patient[exact_report_match])
), by = tumor_type]
setorder(slide_report_audit, tumor_type)
fwrite(slide_report_audit,
       "results/tables/slide_report_coverage_audit.csv")
fwrite(
  selected_slide_reports[exact_report_match == FALSE,
                         .(patient, filename, sample_barcode)],
  "results/tables/slide_report_unmatched_slides.csv"
)

slide_multiplicity <- meta[, .(
  patients = .N,
  eligible_slides = sum(n_slides),
  single_slide_patients = sum(n_slides == 1L),
  multi_slide_patients = sum(n_slides > 1L),
  maximum_slides_per_patient = max(n_slides),
  patients_with_multiple_primary_sample_barcodes =
    sum(n_primary_sample_barcodes > 1L),
  exact_report_matched_slides = sum(exact_report_slides)
), by = tumor_type]
setorder(slide_multiplicity, tumor_type)
fwrite(slide_multiplicity,
       "results/tables/patient_slide_multiplicity_by_cancer.csv")

summary <- meta[, .(
  patients = .N,
  slides = sum(n_slides),
  multi_slide_patients = sum(n_slides > 1),
  report_covered_patients = sum(report_covered),
  exact_report_matched_slides = sum(exact_report_slides),
  patients_with_multiple_primary_sample_barcodes =
    sum(n_primary_sample_barcodes > 1L),
  missing_cancer = sum(is.na(tumor_type))
)]
print(summary)
