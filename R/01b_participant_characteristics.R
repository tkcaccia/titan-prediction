suppressPackageStartupMessages({
  library(data.table)
  library(readxl)
})
source("R/utils.R")
cfg <- load_project_config()
assert_files(cfg$paths["tcga_cdr"])

cohort <- readRDS("data/processed/patient_cohort.rds")
meta <- as.data.table(cohort$meta)[, .(patient, tumor_type)]

cdr <- as.data.table(read_excel(
  cfg$paths$tcga_cdr, na = c("", "NA"), col_types = "text"
))
setnames(cdr, "bcr_patient_barcode", "patient")
stopifnot(!anyDuplicated(cdr$patient))
cdr <- cdr[, .(
  patient,
  cdr_tumor_type = type,
  age = as.numeric(age_at_initial_pathologic_diagnosis),
  recorded_gender = toupper(trimws(gender)),
  recorded_race = toupper(trimws(race)),
  pathologic_stage = trimws(ajcc_pathologic_tumor_stage),
  clinical_stage = trimws(clinical_stage)
)]

unavailable <- function(x) {
  is.na(x) | !nzchar(trimws(x)) | grepl("^\\[", trimws(x))
}
cdr[!is.finite(age) | age < 0 | age > 120, age := NA_real_]
cdr[unavailable(recorded_gender), recorded_gender := NA_character_]
cdr[unavailable(recorded_race), recorded_race := NA_character_]
cdr[, stage_source := fifelse(
  !unavailable(pathologic_stage), pathologic_stage,
  fifelse(!unavailable(clinical_stage), clinical_stage, NA_character_)
)]
cdr[, stage_upper := toupper(stage_source)]
cdr[grepl("/", stage_upper, fixed = TRUE), stage_upper := NA_character_]
cdr[, stage_group := fcase(
  grepl("(^|STAGE[[:space:]]+)IV", stage_upper), "IV",
  grepl("(^|STAGE[[:space:]]+)III", stage_upper), "III",
  grepl("(^|STAGE[[:space:]]+)II", stage_upper), "II",
  grepl("(^|STAGE[[:space:]]+)I", stage_upper), "I",
  default = NA_character_
)]
cdr[, race_group := fcase(
  recorded_race == "WHITE", "White",
  recorded_race == "BLACK OR AFRICAN AMERICAN", "Black or African American",
  recorded_race == "ASIAN", "Asian",
  !is.na(recorded_race), "Other recorded race",
  default = NA_character_
)]

d <- merge(meta, cdr, by = "patient", all.x = TRUE)
d[, cdr_matched := !is.na(cdr_tumor_type)]
d[, cancer_concordant := !is.na(tumor_type) & !is.na(cdr_tumor_type) &
    tumor_type == cdr_tumor_type]

summarise_characteristics <- function(z) {
  data.table(
    patients = nrow(z),
    cdr_matched = sum(z$cdr_matched),
    age_available = sum(is.finite(z$age)),
    age_median = if (any(is.finite(z$age))) median(z$age, na.rm = TRUE) else NA_real_,
    age_q1 = if (any(is.finite(z$age))) quantile(z$age, 0.25, na.rm = TRUE) else NA_real_,
    age_q3 = if (any(is.finite(z$age))) quantile(z$age, 0.75, na.rm = TRUE) else NA_real_,
    female = sum(z$recorded_gender == "FEMALE", na.rm = TRUE),
    male = sum(z$recorded_gender == "MALE", na.rm = TRUE),
    gender_missing = sum(is.na(z$recorded_gender)),
    race_available = sum(!is.na(z$race_group)),
    race_white = sum(z$race_group == "White", na.rm = TRUE),
    race_black_or_african_american =
      sum(z$race_group == "Black or African American", na.rm = TRUE),
    race_asian = sum(z$race_group == "Asian", na.rm = TRUE),
    race_other_recorded = sum(z$race_group == "Other recorded race", na.rm = TRUE),
    race_missing = sum(is.na(z$race_group)),
    stage_available = sum(!is.na(z$stage_group)),
    stage_I = sum(z$stage_group == "I", na.rm = TRUE),
    stage_II = sum(z$stage_group == "II", na.rm = TRUE),
    stage_III = sum(z$stage_group == "III", na.rm = TRUE),
    stage_IV = sum(z$stage_group == "IV", na.rm = TRUE),
    stage_missing_or_other = sum(is.na(z$stage_group))
  )
}

by_cancer <- d[, summarise_characteristics(.SD), by = tumor_type]
by_cancer[is.na(tumor_type), tumor_type := "Unresolved"]
overall <- summarise_characteristics(d)[, tumor_type := "Overall"]
setcolorder(overall, names(by_cancer))
characteristics <- rbind(overall, by_cancer, use.names = TRUE)
characteristics[, order_key := match(
  tumor_type,
  c("Overall", sort(unique(na.omit(meta$tumor_type))), "Unresolved")
)]
setorder(characteristics, order_key)
characteristics[, order_key := NULL]
fwrite(characteristics,
       "results/tables/participant_characteristics_by_cancer.csv")

match_audit <- d[, .(
  cohort_patients = .N,
  cdr_matched = sum(cdr_matched),
  cdr_missing = sum(!cdr_matched),
  concordant_cancer_labels = sum(cancer_concordant),
  discordant_cancer_labels = sum(cdr_matched & !is.na(tumor_type) &
                                  !cancer_concordant)
), by = tumor_type]
match_audit[is.na(tumor_type), tumor_type := "Unresolved"]
setorder(match_audit, tumor_type)
fwrite(match_audit, "results/tables/tcga_cdr_match_audit.csv")

cat("participant characteristics:", nrow(d), "patients;",
    sum(d$cdr_matched), "CDR matches;",
    sum(d$cdr_matched & !is.na(d$tumor_type) & !d$cancer_concordant),
    "cancer-label discordances\n")
