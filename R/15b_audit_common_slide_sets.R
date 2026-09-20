suppressPackageStartupMessages(library(data.table))
source("R/utils.R")
cfg <- load_project_config()

specs <- list(
  TITAN = list(path = cfg$paths$titan_features, pattern = "^titan_[0-9]{3}$"),
  GigaSSL = list(path = cfg$paths$gigassl_features, pattern = "^gigassl_[0-9]{3}$"),
  ProvGigaPath = list(path = cfg$paths$provgigapath_features,
                      pattern = "^provgigapath_[0-9]{3}$")
)
assert_files(lapply(specs, `[[`, "path"))

normalise_slide_id <- function(x) toupper(sub("\\.SVS$", "", basename(as.character(x)),
                                             ignore.case = TRUE))
slides <- lapply(names(specs), function(model) {
  d <- fread(specs[[model]]$path, select = "filename")
  d[, `:=`(
    slide_id = normalise_slide_id(filename),
    patient = substr(toupper(filename), 1L, 12L),
    sample_type = substr(toupper(filename), 14L, 15L)
  )]
  d <- d[sample_type == "01" & grepl("-DX", toupper(filename))]
  if (anyDuplicated(d$slide_id)) stop("Duplicate normalised slide IDs for ", model)
  d[, .(foundation_model = model, patient, slide_id)]
})
names(slides) <- names(specs)

patient_sets <- lapply(slides, function(d) unique(d$patient))
common_patients <- Reduce(intersect, patient_sets)
slides <- lapply(slides, function(d) d[patient %chin% common_patients])

patient_slide_sets <- lapply(slides, function(d) {
  d[, .(slide_set = paste(sort(slide_id), collapse = ";"),
        n_slides = uniqueN(slide_id)), by = patient]
})
audit <- Reduce(function(a, b) merge(a, b, by = "patient", all = TRUE, sort = FALSE),
                Map(function(d, model) {
                  setnames(copy(d), c("slide_set", "n_slides"),
                           c(paste0("slide_set_", model), paste0("n_slides_", model)))
                }, patient_slide_sets, names(patient_slide_sets)))
audit[, identical_slide_sets := slide_set_TITAN == slide_set_GigaSSL &
        slide_set_TITAN == slide_set_ProvGigaPath]
audit[, `:=`(
  max_slide_count = pmax(n_slides_TITAN, n_slides_GigaSSL, n_slides_ProvGigaPath),
  min_slide_count = pmin(n_slides_TITAN, n_slides_GigaSSL, n_slides_ProvGigaPath)
)]
audit[, slide_count_range := max_slide_count - min_slide_count]
audit[, missing_otherwise_eligible_slide := !identical_slide_sets]

common_slide_ids <- Reduce(intersect, lapply(slides, function(d) d$slide_id))
common_slide_map <- unique(slides$TITAN[slide_id %chin% common_slide_ids,
                                       .(patient, slide_id)])
exact_patient_counts <- common_slide_map[, .(exact_common_slides = .N), by = patient]
audit <- merge(audit, exact_patient_counts, by = "patient", all.x = TRUE, sort = FALSE)
audit[is.na(exact_common_slides), exact_common_slides := 0L]
audit[, retains_exact_common_slide := exact_common_slides > 0L]

summary <- data.table(
  common_patients = length(common_patients),
  identical_slide_set_patients = sum(audit$identical_slide_sets),
  identical_slide_set_percent = 100 * mean(audit$identical_slide_sets),
  patients_with_any_slide_set_difference = sum(!audit$identical_slide_sets),
  patients_retained_exact_common_slide = sum(audit$retains_exact_common_slide),
  exact_common_slides = length(common_slide_ids),
  titan_slides_common_patients = nrow(slides$TITAN),
  gigassl_slides_common_patients = nrow(slides$GigaSSL),
  provgigapath_slides_common_patients = nrow(slides$ProvGigaPath),
  maximum_within_patient_slide_count_range = max(audit$slide_count_range),
  median_within_patient_slide_count_range = median(audit$slide_count_range)
)
distribution <- audit[, .N, by = .(slide_count_range, identical_slide_sets)][
  order(slide_count_range, -identical_slide_sets)]
distribution[, percent_common_patients := 100 * N / nrow(audit)]

audit_public_columns <- setdiff(names(audit), grep("^slide_set_", names(audit), value = TRUE))
fwrite(audit[, ..audit_public_columns],
       "results/tables/foundation_model_patient_slide_set_audit.csv")
fwrite(summary, "results/tables/foundation_model_slide_set_summary.csv")
fwrite(distribution, "results/tables/foundation_model_slide_count_difference_distribution.csv")

# Build an exact-common-slide patient cohort for each representation. Patients
# with no slide shared by all three resources are excluded from this sensitivity.
base_meta <- fread("results/tables/patient_cohort_summary.csv")
for (model in names(specs)) {
  spec <- specs[[model]]
  d <- fread(spec$path)
  features <- grep(spec$pattern, names(d), value = TRUE)
  d[, slide_id := normalise_slide_id(filename)]
  d <- d[slide_id %chin% common_slide_ids]
  d[, patient := substr(slide_id, 1L, 12L)]
  setorder(d, patient, slide_id)
  patient_order <- unique(d$patient)
  group <- match(d$patient, patient_order)
  X_slide <- as.matrix(d[, ..features]); storage.mode(X_slide) <- "double"
  n_slides <- tabulate(group, nbins = length(patient_order))
  X <- rowsum(X_slide, group, reorder = FALSE) / n_slides
  rownames(X) <- patient_order; colnames(X) <- features
  meta <- data.table(patient = patient_order, n_slides = n_slides)
  meta <- merge(meta, base_meta[, .(patient, tumor_type, tissue_source_site)],
                by = "patient", all.x = TRUE, sort = FALSE)
  meta[, cohort_order := match(patient, patient_order)]
  setorder(meta, cohort_order); meta[, cohort_order := NULL]
  cohort <- list(
    X = X, meta = meta, feature_names = features, foundation_model = model,
    aggregation = "arithmetic mean across exact slides shared by all three embedding resources",
    slide_intersection = "exact normalised TCGA diagnostic-slide identifier",
    source_file = normalizePath(spec$path),
    source_sha256 = digest::digest(file = spec$path, algo = "sha256"),
    common_slide_ids_sha256 = digest::digest(sort(common_slide_ids), algo = "sha256")
  )
  saveRDS(cohort, file.path("data/processed", paste0("patient_cohort_exact_slides_", model, ".rds")),
          compress = "xz")
}

print(summary)
print(distribution)
