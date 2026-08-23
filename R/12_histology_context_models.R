.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
  library(readxl)
})
source("R/utils.R")
cfg <- load_project_config()
options(fastPLS.backend = tolower(Sys.getenv("TITAN_BACKEND", "cpu")))

dir.create("results/predictions", recursive = TRUE, showWarnings = FALSE)
dir.create("results/tables", recursive = TRUE, showWarnings = FALSE)
cohort <- readRDS("data/processed/patient_cohort.rds")

bootstrap_interval <- function(truth, estimate, statistic, seed, times = 2000L) {
  set.seed(seed)
  values <- replicate(times, {
    i <- sample.int(length(truth), replace = TRUE)
    statistic(truth[i], estimate[i])
  })
  unname(quantile(values[is.finite(values)], c(0.025, 0.975)))
}

# -----------------------------------------------------------------------------
# 1. Pan-cancer cancer-type classification at the patient level.
# Each participant contributes once: eligible primary diagnostic slides were
# mean-pooled before any cross-validation (see R/01_build_patient_cohort.R).
# -----------------------------------------------------------------------------
keep <- !is.na(cohort$meta$tumor_type)
X_cancer <- cohort$X[keep, , drop = FALSE]
y_cancer <- droplevels(factor(cohort$meta$tumor_type[keep]))
cancer_fit <- pls.double.cv(
  X_cancer, y_cancer,
  ncomp = cfg$analysis$components,
  classifier = "lda", lda_ridge = cfg$analysis$lda_ridge,
  selection_metric = "balanced_accuracy",
  svd.method = cfg$analysis$svd_method,
  rsvd_oversample = cfg$analysis$rsvd_oversample,
  rsvd_power = cfg$analysis$rsvd_power,
  kfold_outer = cfg$analysis$outer_folds,
  kfold_inner = cfg$analysis$inner_folds,
  seed = cfg$analysis$seed + 1200L, perm.test = FALSE
)
cancer_pred <- factor(cancer_fit$Ypred, levels = levels(y_cancer))
overall_accuracy <- mean(cancer_pred == y_cancer)
macro_recall <- balanced_accuracy(y_cancer, cancer_pred)
accuracy_ci <- bootstrap_interval(
  y_cancer, cancer_pred, function(a, b) mean(a == b),
  cfg$analysis$seed + 1201L
)
macro_recall_ci <- bootstrap_interval(
  y_cancer, cancer_pred, balanced_accuracy,
  cfg$analysis$seed + 1202L
)
conf <- table(truth = y_cancer, predicted = cancer_pred)
per_class <- data.table(
  tumor_type = rownames(conf), support = rowSums(conf),
  correctly_classified = diag(conf), recall = diag(conf) / rowSums(conf)
)
setorder(per_class, -recall, -support)
fwrite(per_class, "results/tables/cancer_type_per_class.csv")
fwrite(as.data.table(as.data.frame(conf)),
       "results/tables/cancer_type_confusion_matrix_long.csv")
fwrite(data.table(
  task = "TCGA cancer type (32 classes)", n = length(y_cancer),
  classes = nlevels(y_cancer), accuracy = overall_accuracy,
  accuracy_ci_low = accuracy_ci[1], accuracy_ci_high = accuracy_ci[2],
  balanced_accuracy_macro_recall = macro_recall,
  balanced_accuracy_ci_low = macro_recall_ci[1],
  balanced_accuracy_ci_high = macro_recall_ci[2],
  selected_components = as.character(cancer_fit$bcomp),
  validation = "nested 5-fold patient-level cross-validation",
  classifier = "PLS-LDA", svd_method = cfg$analysis$svd_method,
  seed = cfg$analysis$seed + 1200L
), "results/tables/cancer_type_summary.csv")
saveRDS(data.table(
  patient = cohort$meta$patient[keep], observed = as.character(y_cancer),
  predicted = as.character(cancer_pred)
), "results/predictions/cancer_type_oof_predictions.rds", compress = "xz")
dir.create("models/histology_context", recursive = TRUE, showWarnings = FALSE)
cancer_final <- fastPLS::pls(
  X_cancer, y_cancer, ncomp = as.integer(cancer_fit$bcomp),
  classifier = "lda", lda_ridge = cfg$analysis$lda_ridge, fit = TRUE,
  return_loadings = TRUE, svd.method = cfg$analysis$svd_method,
  rsvd_oversample = cfg$analysis$rsvd_oversample,
  rsvd_power = cfg$analysis$rsvd_power,
  seed = cfg$analysis$seed + 1250L
)
cancer_final$Ttrain <- NULL
cancer_final$Yfit <- NULL
saveRDS(list(
  model = cancer_final, feature_names = cohort$feature_names,
  endpoint = "TCGA cancer type", classes = levels(y_cancer),
  training_n = length(y_cancer), unit = "patient-level mean-pooled diagnostic WSI",
  validation_table = "results/tables/cancer_type_summary.csv",
  external_validation = FALSE,
  contains_patient_level_training_rows = FALSE
), "models/histology_context/cancer_type_pls_lda.rds", compress = "xz")

# -----------------------------------------------------------------------------
# 2. Consensus purity estimate (CPE), evaluated separately within each cancer.
# CPE is from Aran, Sirota & Butte, Nature Communications 2015, Supplementary
# Data 1. TCGA participants are matched because pathology slide barcodes use a
# tissue-slide vial (for example, 01Z), whereas molecular purity records use a
# molecular analyte vial (for example, 01A). Multiple primary-tumour CPE
# aliquots for a participant are averaged.
# -----------------------------------------------------------------------------
purity_file <- "data/raw/Aran2015_tumor_purity_Supplementary_Data_1.xlsx"
purity_url <- paste0(
  "https://media.springernature.com/original/springer-static/esm/",
  "art%3A10.1038%2Fncomms9971/MediaObjects/",
  "41467_2015_BFncomms9971_MOESM1236_ESM.xlsx"
)
if (!file.exists(purity_file)) {
  stop("Missing published CPE supplementary file. Download: ", purity_url)
}
purity <- as.data.table(read_excel(purity_file, sheet = "Supp Data 1", skip = 3))
setnames(purity, names(purity), make.names(names(purity), unique = TRUE))
stopifnot(all(c("Sample.ID", "Cancer.type", "CPE") %in% names(purity)))
purity[, `:=`(
  sample_barcode = substr(as.character(Sample.ID), 1, 16),
  patient = substr(as.character(Sample.ID), 1, 12),
  cpe = suppressWarnings(as.numeric(CPE))
)]

slides <- fread(cfg$paths$titan_features, select = "filename")
slides[, `:=`(
  patient = substr(filename, 1, 12),
  sample_barcode = substr(filename, 1, 16),
  sample_type = substr(filename, 14, 15)
)]
eligible_samples <- unique(slides[sample_type == "01" & grepl("-DX", filename),
                                   .(patient, sample_barcode)])
eligible_patients <- unique(eligible_samples[, .(patient)])
purity_matched <- merge(
  eligible_patients,
  purity[is.finite(cpe) & substr(sample_barcode, 14, 15) == "01",
         .(patient, molecular_sample_barcode = sample_barcode, cpe)],
  by = "patient", all = FALSE
)
purity_patient <- purity_matched[, .(
  cpe = mean(cpe), matched_molecular_sample_barcodes =
    uniqueN(molecular_sample_barcode)
), by = patient]
purity_patient[, tumor_type := cohort$meta$tumor_type[
  match(patient, cohort$meta$patient)
]]
purity_jobs <- purity_patient[, .N, by = tumor_type][N >= 50 & !is.na(tumor_type)]

run_purity <- function(i) {
  cancer <- purity_jobs$tumor_type[i]
  d <- purity_patient[tumor_type == cancer]
  idx <- match(d$patient, rownames(cohort$X))
  fit <- pls.double.cv(
    cohort$X[idx, , drop = FALSE], d$cpe,
    ncomp = cfg$analysis$components,
    svd.method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    kfold_outer = cfg$analysis$outer_folds,
    kfold_inner = cfg$analysis$inner_folds,
    seed = cfg$analysis$seed + 1300L + i, perm.test = FALSE
  )
  pred <- as.numeric(fit$Ypred)
  set.seed(cfg$analysis$seed + 1350L + i)
  boot <- replicate(1000L, {
    b <- sample.int(nrow(d), replace = TRUE)
    c(
      q2 = q_squared(d$cpe[b], pred[b]),
      rmse = sqrt(mean((d$cpe[b] - pred[b])^2)),
      spearman = suppressWarnings(cor(d$cpe[b], pred[b], method = "spearman"))
    )
  })
  ci <- apply(boot, 1L, quantile, probs = c(0.025, 0.975), na.rm = TRUE)
  list(
    summary = data.table(
      tumor_type = cancer, n = nrow(d),
      q2 = q_squared(d$cpe, pred),
      q2_ci_low = ci[1, "q2"], q2_ci_high = ci[2, "q2"],
      rmse = sqrt(mean((d$cpe - pred)^2)),
      rmse_ci_low = ci[1, "rmse"], rmse_ci_high = ci[2, "rmse"],
      spearman = suppressWarnings(cor(d$cpe, pred, method = "spearman")),
      spearman_ci_low = ci[1, "spearman"],
      spearman_ci_high = ci[2, "spearman"],
      selected_components = as.character(fit$bcomp),
      validation = "nested 5-fold patient-level cross-validation",
      svd_method = cfg$analysis$svd_method,
      seed = cfg$analysis$seed + 1300L + i
    ),
    predictions = data.table(
      patient = d$patient, tumor_type = cancer, observed_cpe = d$cpe,
      predicted_cpe = pred
    )
  )
}
workers <- min(as.integer(Sys.getenv("TITAN_WORKERS", "6")), nrow(purity_jobs))
future::plan(future::multicore, workers = workers)
purity_results <- future_lapply(
  seq_len(nrow(purity_jobs)), run_purity, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table"), future.globals = TRUE
)
future::plan(future::sequential)
purity_summary <- rbindlist(lapply(purity_results, `[[`, "summary"))
setorder(purity_summary, -q2)
fwrite(purity_summary, "results/tables/purity_cpe_screen.csv")
saveRDS(rbindlist(lapply(purity_results, `[[`, "predictions")),
        "results/predictions/purity_cpe_oof_predictions.rds", compress = "xz")

# Save fitted models for endpoints with positive cross-validated explained
# variance. The validation table remains authoritative for model selection.
purity_models <- lapply(seq_len(nrow(purity_summary)), function(i) {
  row <- purity_summary[i]
  if (row$q2 <= 0) return(NULL)
  d <- purity_patient[tumor_type == row$tumor_type]
  idx <- match(d$patient, rownames(cohort$X))
  fit <- fastPLS::pls(
    cohort$X[idx, , drop = FALSE], d$cpe,
    ncomp = as.integer(row$selected_components), fit = TRUE,
    return_loadings = TRUE, svd.method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    seed = as.integer(row$seed) + 50L
  )
  fit$Ttrain <- NULL
  fit$Yfit <- NULL
  list(
    model = fit, feature_names = cohort$feature_names,
    endpoint = "consensus purity estimate (CPE)",
    tumor_type = row$tumor_type, training_n = nrow(d),
    unit = "patient-level mean-pooled diagnostic WSI",
    source_doi = "10.1038/ncomms9971", external_validation = FALSE,
    contains_patient_level_training_rows = FALSE
  )
})
names(purity_models) <- purity_summary$tumor_type
purity_models <- purity_models[!vapply(purity_models, is.null, logical(1))]
saveRDS(purity_models, "models/histology_context/purity_cpe_pls_models.rds",
        compress = "xz")
fwrite(data.table(
  source = "Aran, Sirota & Butte (2015), Supplementary Data 1",
  doi = "10.1038/ncomms9971", source_url = purity_url,
  local_file = purity_file,
  sha256 = digest::digest(file = purity_file, algo = "sha256"),
  published_rows_with_finite_cpe = purity[is.finite(cpe), .N],
  participant_matched_primary_molecular_samples = nrow(purity_matched),
  matched_patients = nrow(purity_patient),
  patients_with_multiple_matched_molecular_barcodes =
    purity_patient[matched_molecular_sample_barcodes > 1, .N],
  matching_note = paste(
    "Participant-level match: pathology slide vials (01Z) and molecular",
    "purity analyte vials (01A) are not the same sample barcode."
  )
), "results/tables/purity_cpe_provenance.csv")

# -----------------------------------------------------------------------------
# 3. Paired tumour-versus-adjacent-normal feasibility experiment.
# The only normal TITAN slides currently available are 12 matched KICH pairs.
# Leave-one-patient-out validation prevents the tumour and normal slides from
# the same patient appearing on opposite sides of an outer split.
# -----------------------------------------------------------------------------
normal_patients <- unique(slides[sample_type == "11", patient])
paired_slides <- fread(cfg$paths$titan_features)
feature_names <- cohort$feature_names
paired_slides[, `:=`(
  patient = substr(filename, 1, 12),
  sample_type = substr(filename, 14, 15),
  sample_barcode = substr(filename, 1, 16)
)]
paired_slides <- paired_slides[
  patient %in% normal_patients & sample_type %in% c("01", "11")
]
paired <- paired_slides[, c(
  list(label = ifelse(sample_type[1] == "01", "tumour", "normal")),
  lapply(.SD, mean)
), by = .(patient, sample_type), .SDcols = feature_names]
stopifnot(all(paired[, .N, by = patient]$N == 2L))
setorder(paired, patient, sample_type)
X_pair <- as.matrix(paired[, ..feature_names])
y_pair <- factor(paired$label, levels = c("normal", "tumour"))
groups <- paired$patient
pair_pred <- factor(rep(NA_character_, nrow(paired)), levels = levels(y_pair))
pair_score <- rep(NA_real_, nrow(paired))
pair_ncomp <- integer(length(normal_patients))

for (outer_i in seq_along(normal_patients)) {
  test_group <- normal_patients[outer_i]
  train <- groups != test_group
  test <- !train
  inner_groups <- unique(groups[train])
  inner_ba <- rep(NA_real_, length(cfg$analysis$components))
  for (ci in seq_along(cfg$analysis$components)) {
    component <- cfg$analysis$components[ci]
    inner_truth <- inner_pred <- character()
    for (inner_i in seq_along(inner_groups)) {
      validation_group <- inner_groups[inner_i]
      inner_test <- train & groups == validation_group
      inner_train <- train & groups != validation_group
      fit <- fastPLS::pls(
        X_pair[inner_train, , drop = FALSE], y_pair[inner_train],
        ncomp = component, classifier = "lda",
        lda_ridge = cfg$analysis$lda_ridge, fit = TRUE,
        svd.method = cfg$analysis$svd_method,
        rsvd_oversample = cfg$analysis$rsvd_oversample,
        rsvd_power = cfg$analysis$rsvd_power,
        seed = cfg$analysis$seed + 1400L + outer_i * 100L + inner_i
      )
      z <- predict(fit, X_pair[inner_test, , drop = FALSE])$Ypred[[1]]
      inner_truth <- c(inner_truth, as.character(y_pair[inner_test]))
      inner_pred <- c(inner_pred, as.character(z))
    }
    inner_ba[ci] <- balanced_accuracy(inner_truth, inner_pred)
  }
  pair_ncomp[outer_i] <- cfg$analysis$components[which.max(inner_ba)]
  fit <- fastPLS::pls(
    X_pair[train, , drop = FALSE], y_pair[train], ncomp = pair_ncomp[outer_i],
    classifier = "lda", lda_ridge = cfg$analysis$lda_ridge, fit = TRUE,
    svd.method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    seed = cfg$analysis$seed + 1500L + outer_i
  )
  z <- predict(fit, X_pair[test, , drop = FALSE], raw_scores = TRUE)
  pair_pred[test] <- z$Ypred[[1]]
  pair_score[test] <- drop(z$LDA_scores[, 2, 1] - z$LDA_scores[, 1, 1])
}
pair_metrics <- binary_classification_metrics(
  factor(as.integer(y_pair == "tumour"), levels = c(0, 1)),
  factor(as.integer(pair_pred == "tumour"), levels = c(0, 1)), pair_score
)
fwrite(cbind(data.table(
  task = "KICH primary tumour versus paired adjacent normal", pairs = 12L,
  observations = nrow(paired), validation = "nested leave-one-patient-out",
  classifier = "PLS-LDA", selected_components_by_outer_fold =
    paste(pair_ncomp, collapse = ";"), svd_method = cfg$analysis$svd_method,
  development_status = "insufficient sample; descriptive pilot only",
  eligible_for_manuscript_claim = FALSE,
  eligible_for_deployment = FALSE
), pair_metrics), "results/tables/tumor_normal_kich_paired_summary.csv")
fwrite(data.table(
  patient = paired$patient, sample_type = paired$sample_type,
  observed = as.character(y_pair), predicted = as.character(pair_pred),
  lda_tumour_score = pair_score
), "results/tables/tumor_normal_kich_paired_predictions.csv")

cat("Cancer type accuracy:", overall_accuracy, "macro recall:", macro_recall, "\n")
print(purity_summary)
print(pair_metrics)
