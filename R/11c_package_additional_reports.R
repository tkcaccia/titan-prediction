.libPaths(c(file.path(getwd(), ".Rlib"), .libPaths()))

suppressPackageStartupMessages({
  library(data.table)
  library(PathoFMPred)
})

patient_ids <- c("TCGA-AA-A01F", "TCGA-A6-A56B")
example_names <- c(
  "TCGA-AA-A01F" = "COAD_example_A",
  "TCGA-A6-A56B" = "COAD_example_B"
)
foundation_models <- c("TITAN", "GigaSSL", "ProvGigaPath")

context_table <- fread(file.path(
  "results", "tables", "coad_package_examples.csv"
))

report_dir <- file.path("results", "reports", "package_sections")
dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)

report_manifest <- list()

for (sample_id in patient_ids) {
  context_row <- context_table[patient_id == sample_id]
  if (nrow(context_row) != 1L) {
    stop("Expected one context row for ", sample_id, ".")
  }

  clinical_context <- as.list(context_row[, .(
    shared_features, pathology, source
  )])

  for (foundation_model in foundation_models) {
    cohort_path <- file.path(
      "data", "processed", paste0("patient_cohort_", foundation_model, ".rds")
    )
    cohort <- readRDS(cohort_path)
    patient_index <- match(sample_id, cohort$meta$patient)
    if (is.na(patient_index)) {
      stop(sample_id, " is unavailable for ", foundation_model, ".")
    }

    output_stem <- file.path(
      report_dir,
      paste0(example_names[[sample_id]], "_", foundation_model)
    )

    output <- pathofm_sample_report(
      cancer = "COAD",
      features = cohort$X[patient_index, , drop = FALSE],
      foundation_model = foundation_model,
      patient_id = sample_id,
      output_file = output_stem,
      format = "pdf",
      clinical_context = clinical_context,
      include_limited_evidence = FALSE,
      quiet = TRUE
    )

    report_manifest[[length(report_manifest) + 1L]] <- data.table(
      patient_id = sample_id,
      example = unname(example_names[[sample_id]]),
      foundation_model = foundation_model,
      report_pdf = normalizePath(output, mustWork = TRUE)
    )
  }
}

manifest <- rbindlist(report_manifest)
fwrite(
  manifest,
  file.path("results", "reports", "package_sections", "report_manifest.csv")
)

message(
  "Generated ", nrow(manifest),
  " PathoFMPred package report sections for the two COAD examples."
)
