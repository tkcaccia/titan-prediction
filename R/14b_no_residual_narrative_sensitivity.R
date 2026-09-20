.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
})
source("R/utils.R")

cfg <- load_project_config()
backend <- tolower(Sys.getenv("TITAN_BACKEND", "cpu"))
options(backend = backend)

cohort <- readRDS("data/processed/patient_cohort.rds")
continuous_targets <- readRDS("data/processed/continuous_targets.rds")
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)

flagged <- fread("results/tables/pathology_qc_no_residual_patient_audit.csv")
stopifnot(nrow(flagged) > 0L)
flagged[, tumor_type := sub("^TCGA-", "", project_id)]
flagged_by_cancer <- split(flagged$patient, flagged$tumor_type)
affected_cancers <- names(flagged_by_cancer)

continuous_jobs <- fread("results/tables/continuous_screen.csv")[
  tier %in% c("A", "B") & tumor_type %in% affected_cancers
]
binary_jobs <- fread("results/tables/binary_screen.csv")[
  tier %in% c("A", "B") & tumor_type %in% affected_cancers
]
highlighted <- fread("results/tables/highlighted_model_performance.csv")[
  , .(family, tumor_type, endpoint, outcome_type)
]

fit_cont <- function(job, excluded_patients) {
  d <- continuous_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  d <- d[!patient %in% excluded_patients]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx) & is.finite(d$value)
  fit <- pls.double.cv(
    cohort$X[idx[keep], , drop = FALSE], d$value[keep],
    ncomp = cfg$analysis$components, rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    kfold_outer = cfg$analysis$outer_folds,
    kfold_inner = cfg$analysis$inner_folds,
    seed = job$seed,
    perm.test = FALSE
  )
  list(n = sum(keep), metric = as.numeric(fit$Q2Y))
}

fit_binary <- function(job, excluded_patients) {
  d <- binary_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  d <- d[!patient %in% excluded_patients]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx) & d$value %in% c(0L, 1L)
  y <- factor(d$value[keep], levels = c(0L, 1L))
  fit <- pls.double.cv(
    cohort$X[idx[keep], , drop = FALSE], y,
    ncomp = cfg$analysis$components,
    classifier = "lda", selection = "balanced_accuracy", rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    kfold_outer = cfg$analysis$outer_folds,
    kfold_inner = cfg$analysis$inner_folds,
    seed = job$seed,
    perm.test = FALSE
  )
  list(
    n = sum(keep),
    positive = sum(y == "1"),
    negative = sum(y == "0"),
    metric = balanced_accuracy(y, fit$Ypred)
  )
}

run_cont <- function(i) {
  job <- continuous_jobs[i]
  excluded <- flagged_by_cancer[[job$tumor_type]]
  z <- fit_cont(job, excluded)
  out <- data.table(
    outcome_type = "continuous",
    family = job$family,
    tumor_type = job$tumor_type,
    endpoint = job$endpoint,
    original_n = job$n,
    exclusion_n = z$n,
    excluded_patient_count = length(excluded),
    excluded_patient_ids = paste(excluded, collapse = ";"),
    original_effect = job$q2,
    exclusion_effect = z$metric,
    delta_exclusion_minus_original = z$metric - job$q2,
    original_threshold_retained = z$metric >= 0.20,
    seed = job$seed
  )
  out
}

run_binary <- function(i) {
  job <- binary_jobs[i]
  excluded <- flagged_by_cancer[[job$tumor_type]]
  z <- fit_binary(job, excluded)
  data.table(
    outcome_type = "binary",
    family = job$family,
    tumor_type = job$tumor_type,
    endpoint = job$endpoint,
    original_n = job$n,
    exclusion_n = z$n,
    exclusion_positive = z$positive,
    exclusion_negative = z$negative,
    excluded_patient_count = length(excluded),
    excluded_patient_ids = paste(excluded, collapse = ";"),
    original_effect = job$balanced_accuracy,
    exclusion_effect = z$metric,
    delta_exclusion_minus_original = z$metric - job$balanced_accuracy,
    original_threshold_retained = z$metric >= 0.60,
    seed = job$seed
  )
}

# Run this small affected-cancer audit sequentially.  This keeps its seeded
# rSVD/CV fits independent of fork scheduling and exactly reproducible from a
# clean R session.
continuous_sensitivity <- rbindlist(lapply(
  seq_len(nrow(continuous_jobs)), run_cont
))
binary_sensitivity <- rbindlist(lapply(
  seq_len(nrow(binary_jobs)), run_binary
))

all_sensitivity <- rbindlist(
  list(continuous_sensitivity, binary_sensitivity),
  fill = TRUE,
  use.names = TRUE
)
all_sensitivity <- merge(
  all_sensitivity,
  highlighted[, .(family, tumor_type, endpoint, outcome_type, highlighted_model = TRUE)],
  by = c("family", "tumor_type", "endpoint", "outcome_type"),
  all.x = TRUE
)
all_sensitivity[is.na(highlighted_model), highlighted_model := FALSE]
# This is a descriptive sensitivity marker, not an inferential threshold.
all_sensitivity[, material_change_flag :=
  !original_threshold_retained | abs(delta_exclusion_minus_original) >= 0.05]
all_sensitivity[, sensitivity_scope := paste0(
  "non-adjudicated exclusion of all patients in the cancer with a generated ",
  "no-residual-tumour narrative mention; not pathology-adjudicated QC"
)]
setorder(all_sensitivity, outcome_type, tumor_type, family, endpoint)

fwrite(
  all_sensitivity[outcome_type == "continuous"],
  "results/tables/nonadjudicated_no_residual_exclusion_continuous.csv"
)
fwrite(
  all_sensitivity[outcome_type == "binary"],
  "results/tables/nonadjudicated_no_residual_exclusion_binary.csv"
)
fwrite(
  all_sensitivity,
  "results/tables/nonadjudicated_no_residual_exclusion_all.csv"
)

summary <- all_sensitivity[, .(
  models = .N,
  affected_cancers = uniqueN(tumor_type),
  highlighted_models = sum(highlighted_model),
  median_delta = median(delta_exclusion_minus_original),
  q05_delta = quantile(delta_exclusion_minus_original, 0.05),
  q95_delta = quantile(delta_exclusion_minus_original, 0.95),
  threshold_retained = sum(original_threshold_retained),
  threshold_not_retained = sum(!original_threshold_retained),
  material_change_flags = sum(material_change_flag),
  highlighted_material_change_flags = sum(material_change_flag & highlighted_model)
), by = outcome_type]
fwrite(
  summary,
  "results/tables/nonadjudicated_no_residual_exclusion_summary.csv"
)

fwrite(
  all_sensitivity[highlighted_model == TRUE],
  "results/tables/nonadjudicated_no_residual_exclusion_highlighted.csv"
)

print(flagged[, .(
  patient,
  tumor_type,
  narrative_no_residual_tumour_slides,
  n_slides
)])
print(summary)
print(all_sensitivity[highlighted_model == TRUE])
