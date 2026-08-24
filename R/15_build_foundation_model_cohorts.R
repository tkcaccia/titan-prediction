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

base_meta <- fread("results/tables/patient_cohort_summary.csv")
cohort_audit <- list()
for (model in names(specs)) {
  spec <- specs[[model]]
  d <- fread(spec$path)
  features <- grep(spec$pattern, names(d), value = TRUE)
  if (!length(features)) stop("No features found for ", model)
  d[, patient := substr(filename, 1, 12)]
  d[, sample_type := substr(filename, 14, 15)]
  d <- d[sample_type == "01" & grepl("-DX", filename)]
  if (anyDuplicated(d$filename)) stop("Duplicate slide IDs for ", model)
  patient_order <- unique(d$patient)
  group <- match(d$patient, patient_order)
  X_slide <- as.matrix(d[, ..features])
  storage.mode(X_slide) <- "double"
  if (any(!is.finite(X_slide))) stop("Non-finite features for ", model)
  n_slides <- tabulate(group, nbins = length(patient_order))
  X <- rowsum(X_slide, group, reorder = FALSE) / n_slides
  rownames(X) <- patient_order
  colnames(X) <- features
  meta <- data.table(patient = patient_order, n_slides = n_slides)
  meta <- merge(meta, base_meta[, .(patient, tumor_type, tissue_source_site)],
                by = "patient", all.x = TRUE, sort = FALSE)
  meta[, cohort_order := match(patient, patient_order)]
  setorder(meta, cohort_order)
  meta[, cohort_order := NULL]
  cohort <- list(
    X = X, meta = meta, feature_names = features,
    foundation_model = model,
    aggregation = "arithmetic mean across primary-tumour diagnostic slides",
    source_file = normalizePath(spec$path),
    source_sha256 = digest::digest(file = spec$path, algo = "sha256")
  )
  out <- file.path("data/processed", paste0("patient_cohort_", model, ".rds"))
  saveRDS(cohort, out, compress = "xz")
  cohort_audit[[model]] <- data.table(
    foundation_model = model, source_slides = nrow(d), patients = nrow(meta),
    dimensions = ncol(X), multi_slide_patients = sum(n_slides > 1),
    maximum_slides = max(n_slides), resolved_cancer_patients = sum(!is.na(meta$tumor_type)),
    source_sha256 = cohort$source_sha256
  )
}

audit <- rbindlist(cohort_audit)
patient_sets <- lapply(names(specs), function(model) {
  rownames(readRDS(file.path("data/processed", paste0("patient_cohort_", model, ".rds")))$X)
})
names(patient_sets) <- names(specs)
audit[, common_three_model_patients := length(Reduce(intersect, patient_sets))]
fwrite(audit, "results/tables/foundation_model_cohort_audit.csv")
print(audit)
