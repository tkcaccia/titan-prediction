suppressPackageStartupMessages(library(data.table))
source("R/utils.R")
cfg <- load_project_config()
assert_files(cfg$paths[c("titan_features", "slide_reports")])

titan <- fread(cfg$paths$titan_features)
titan[, patient := substr(filename, 1, 12)]
titan[, sample_type := substr(filename, 14, 15)]
titan <- titan[sample_type == "01" & grepl("-DX", filename)]
titan[, match_key := tolower(filename)]

reports <- fread(cfg$paths$slide_reports)
reports[, match_key := tolower(slide_id)]
selected <- merge(
  titan[, .(patient, filename, match_key)],
  reports[, .(match_key, slide_id, project_id,
              site_of_resection_or_biopsy, slide_reports, case_reports)],
  by = "match_key", all.x = TRUE
)
stopifnot(nrow(selected) == nrow(titan))

# TCGA-Slide-Reports.csv contains generated narrative text, not structured or
# pathologist-adjudicated slide-QC fields. The expressions below are therefore
# an audit of narrative mentions only; they must not be used as ground-truth
# tumour percentages, tissue measurements, procedure labels or QC exclusions.
has_text <- function(x, pattern) {
  !is.na(x) & grepl(pattern, x, ignore.case = TRUE, perl = TRUE)
}
selected[, exact_report_match := !is.na(slide_id)]
selected[, narrative_tumour_content_mention := has_text(
  slide_reports,
  "tumou?r (cellularity|content)|percent(age)? (of )?tumou?r|[0-9]+% tumou?r"
)]
selected[, narrative_tissue_area_mention := has_text(
  slide_reports, "tissue area|area of tissue|mm2|mm\\^2|square millimet"
)]
selected[, narrative_artefact_mention := has_text(
  slide_reports,
  "artifact|artefact|tissue fold|crush artifact|cautery artifact|out[- ]of[- ]focus|blur"
)]
selected[, narrative_procedure_mention := has_text(
  slide_reports, "biopsy|resection|excision|ectomy"
)]
selected[, narrative_slide_quality_mention := has_text(
  slide_reports, "slide quality|image quality|poor quality|adequate quality|inadequate quality"
)]
selected[, narrative_no_residual_tumour_mention := has_text(
  slide_reports,
  "no residual (sarcoma|myxofibrosarcoma|tumou?r|malignan|carcinoma|neoplasm)"
)]

fields <- data.table(
  domain = c(
    "Tumour content/cellularity", "Tissue area", "Artefact",
    "Biopsy versus resection", "Slide/image quality",
    "Anatomical resection/biopsy site"
  ),
  structured_field_available = c(FALSE, FALSE, FALSE, FALSE, FALSE, TRUE),
  field_or_evidence = c(
    NA, NA, NA, NA, NA, "site_of_resection_or_biopsy"
  ),
  interpretation = c(
    rep("No structured field; generated narrative mentions are unvalidated and were not used for exclusion or weighting.", 5),
    "Anatomical site only; it does not encode whether the specimen was a biopsy or resection."
  )
)
fwrite(fields, "results/tables/pathology_qc_field_availability.csv")

mention_summary <- selected[, .(
  eligible_slides = .N,
  exact_report_matched_slides = sum(exact_report_match),
  tumour_content_mentions = sum(narrative_tumour_content_mention),
  tissue_area_mentions = sum(narrative_tissue_area_mention),
  artefact_mentions = sum(narrative_artefact_mention),
  procedure_mentions = sum(narrative_procedure_mention),
  slide_quality_mentions = sum(narrative_slide_quality_mention),
  no_residual_tumour_mentions = sum(narrative_no_residual_tumour_mention)
)]
mention_summary[, `:=`(
  narrative_source = "TITAN-generated TCGA-Slide-Reports text",
  used_for_primary_exclusion_or_weighting = FALSE
)]
fwrite(mention_summary, "results/tables/pathology_qc_narrative_audit.csv")

patient_audit <- selected[, .(
  n_slides = .N,
  exact_report_matched_slides = sum(exact_report_match),
  narrative_no_residual_tumour_slides = sum(narrative_no_residual_tumour_mention),
  narrative_artefact_mention_slides = sum(narrative_artefact_mention),
  project_id = paste(sort(unique(na.omit(project_id))), collapse = ";"),
  anatomical_site = paste(sort(unique(na.omit(site_of_resection_or_biopsy))), collapse = ";")
), by = patient]
patient_audit[, within_patient_slide_weight := 1 / n_slides]
setorder(patient_audit, -n_slides, patient)
fwrite(patient_audit, "results/tables/pathology_qc_patient_multiplicity_audit.csv")

max_patient <- patient_audit[1]
stopifnot(max_patient$n_slides == 30L)
fwrite(max_patient, "results/tables/pathology_qc_maximum_slide_patient.csv")

cat("Pathology-QC fields audited; narrative mentions are not adjudicated labels.\n")
print(mention_summary)
print(max_patient)
