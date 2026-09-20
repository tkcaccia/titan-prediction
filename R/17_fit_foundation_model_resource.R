.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
options(backend = tolower(Sys.getenv("TITAN_BACKEND", "cpu")))

screen <- fread("results/tables/foundation_model_matched_screen.csv")
oof <- readRDS("results/predictions/foundation_model_matched_oof.rds")
base_registry <- fread("models/model_registry.csv")
continuous <- readRDS("data/processed/continuous_targets.rds")
binary <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE, fill = TRUE)

# The original TITAN candidate catalogue defines the endpoints distributed in
# the research package. Giga-SSL and Prov-GigaPath are fitted for exactly those
# endpoints, without representation-specific target cherry-picking.
keys <- unique(base_registry[, .(outcome_type, family, tumor_type = cancer_type,
                                 endpoint)])
jobs <- merge(
  screen[foundation_model %chin% c("GigaSSL", "ProvGigaPath")], keys,
  by = c("outcome_type", "family", "tumor_type", "endpoint"),
  all = FALSE
)
setorder(jobs, foundation_model, outcome_type, family, tumor_type, endpoint)

out_dir <- "models/foundation_models"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
registry_rows <- vector("list", nrow(jobs))

fit_resource_model <- function(i) {
  job <- jobs[i]
  cohort <- readRDS(file.path(
    "data/processed", paste0("patient_cohort_", job$foundation_model, ".rds")
  ))
  target <- if (job$outcome_type == "continuous") continuous else binary
  d <- target[family == job$family & tumor_type == job$tumor_type &
                endpoint == job$endpoint]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx)
  if (job$outcome_type == "continuous") keep <- keep & is.finite(d$value)
  else keep <- keep & d$value %in% c(0L, 1L)
  d <- d[keep]
  setorder(d, patient)
  idx <- match(d$patient, rownames(cohort$X))
  X <- cohort$X[idx, , drop = FALSE]
  y <- if (job$outcome_type == "continuous") d$value else
    factor(d$value, levels = c(0L, 1L))
  seed <- cfg$analysis$seed + 200000L + i
  full_binary_rule <- if (job$outcome_type == "binary") {
    select_binary_auroc_rule(
      X, y, rep(TRUE, nrow(X)), cfg$analysis, seed = seed + 50000L
    )
  } else NULL
  ncomp <- if (job$outcome_type == "binary") {
    full_binary_rule$component
  } else {
    max(1L, as.integer(round(job$selected_components_median)))
  }
  fitted <- fit_final_model(X, y, job$outcome_type, ncomp, cfg$analysis, seed)
  fitted$Ttrain <- NULL
  fitted$Yfit <- NULL
  base_id <- safe_name(job$family, job$tumor_type, job$endpoint)
  model_id <- paste(job$foundation_model, base_id, sep = "__")
  new_model_id <- model_id
  transform <- if (job$outcome_type == "continuous")
    continuous_endpoint_transform(job$family, job$endpoint) else "none"
  units <- if (job$outcome_type == "binary")
    "training-threshold class label and uncalibrated LDA score" else if (transform == "log1p")
      "log1p-transformed source endpoint units" else "source endpoint units"
  artifact <- list(
    model = fitted, model_id = model_id,
    foundation_model = job$foundation_model,
    outcome_type = job$outcome_type, family = job$family,
    cancer_type = job$tumor_type, endpoint = job$endpoint,
    feature_names = cohort$feature_names, aggregation = cohort$aggregation,
    ncomp = ncomp, training_n = length(y), endpoint_transform = transform,
    output_units = units,
    positive = if (job$outcome_type == "binary") sum(y == "1") else NA_integer_,
    negative = if (job$outcome_type == "binary") sum(y == "0") else NA_integer_,
    class_labels = if (job$outcome_type == "binary")
      c(wild_type_or_negative = "0", altered_or_positive = "1") else NULL,
    class_priors = if (job$outcome_type == "binary") prop.table(table(y)) else NULL,
    operating_threshold = if (job$outcome_type == "binary")
      full_binary_rule$threshold else NULL,
    validation_operating_threshold_median = if (job$outcome_type == "binary")
      job$operating_threshold_median else NULL,
    primary_binary_decision_rule = if (job$outcome_type == "binary")
      paste(
        "component selected by pooled inner out-of-fold AUROC; operating",
        "threshold selected from full-development inner out-of-fold scores"
      ) else NULL,
    training_feature_min = apply(X, 2L, min),
    training_feature_max = apply(X, 2L, max),
    training_feature_mean = colMeans(X),
    training_feature_sd = apply(X, 2L, sd),
    feature_file_sha256 = cohort$source_sha256,
    feature_schema_sha256 = digest::digest(cohort$feature_names, algo = "sha256"),
    fastPLS_version = as.character(packageVersion("fastPLS")),
    fastPLS_remote_sha = as.character(packageDescription("fastPLS")$RemoteSha),
    backend = getOption("backend"), svd_method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power, fit_seed = seed,
    intended_use = paste(
      "Research use only; internally derived TCGA model without external validation"
    ),
    deployment_metadata = list(
      training_cohort = "TCGA primary-tumour diagnostic slides",
      representation = job$foundation_model,
      input_level = paste(ncol(X), "foundation-model features per slide"),
      slide_aggregation = cohort$aggregation,
      external_validation = "none",
      contains_patient_level_training_rows = FALSE,
      calibration_status = if (job$outcome_type == "binary")
        "uncalibrated; score is not a probability" else "not applicable",
      primary_binary_decision_rule = if (job$outcome_type == "binary")
        paste(
          "component selected by pooled inner out-of-fold AUROC; operating",
          "threshold selected from full-development inner out-of-fold scores"
        ) else "not applicable"
    )
  )
  model_file <- file.path(out_dir, paste0(model_id, ".rds"))
  saveRDS(artifact, model_file, compress = "xz")

  old <- copy(base_registry[
    outcome_type == job$outcome_type & family == job$family &
      cancer_type == job$tumor_type & endpoint == job$endpoint
  ][1])
  inherited_titan_tier <- old$tier
  old[, `:=`(
    foundation_model = job$foundation_model, model_id = new_model_id,
    file = basename(model_file), sha256 = digest::digest(file = model_file, algo = "sha256"),
    n = length(y), positive = artifact$positive, negative = artifact$negative,
    ncomp = ncomp, feature_dimension = ncol(X),
    titan_feature_file_sha256 = cohort$source_sha256,
    feature_schema_sha256 = artifact$feature_schema_sha256,
    screen_q2 = job$q2, screen_rmse = job$rmse,
    screen_spearman = job$spearman,
    screen_balanced_accuracy = job$balanced_accuracy,
    screen_auc = job$auc,
    screen_sensitivity = job$sensitivity,
    screen_specificity = job$specificity,
    screen_ppv = job$ppv,
    screen_npv = job$npv,
    binary_prevalence = job$prevalence,
    binary_no_skill_pr_auc = job$no_skill_pr_auc,
    binary_operating_threshold = if (job$outcome_type == "binary")
      full_binary_rule$threshold else NA_real_,
    binary_operating_threshold_median = job$operating_threshold_median,
    repeated_q2 = NA_real_, repeated_rmse = NA_real_, repeated_spearman = NA_real_,
    repeated_sensitivity = NA_real_, repeated_specificity = NA_real_,
    repeated_balanced_accuracy = NA_real_, repeated_auc = job$auc,
    binary_pr_auc = job$pr_auc,
    primary_estimate_label = "matched-cohort patient-level nested-CV estimate",
    repeated_estimate_label = "not performed for this representation",
    repeated_minus_primary_primary_metric = NA_real_,
    resource_selection_basis = paste(
      "endpoint inherited from the permutation/FDR-qualified TITAN catalogue;",
      "not selected by this representation's performance"
    ),
    representation_specific_qualification = paste(
      "matched-cohort nested-CV estimate only; no representation-specific",
      "permutation/FDR qualification"
    ),
    titan_catalogue_tier = inherited_titan_tier,
    tier_origin = paste(
      "inherited from the TITAN permutation/FDR-qualified endpoint catalogue;",
      "not a representation-specific q-value tier"
    ),
    representation_effect_threshold_crossing = if (job$outcome_type == "continuous")
      job$q2 >= 0.20 else job$auc >= 0.60,
    external_validation = "none",
    site_grouped_metric_name = NA_character_, site_grouped_metric = NA_real_,
    site_performance_delta = NA_real_, site_grouped_n_sites = NA_integer_,
    site_grouped_feasible = FALSE, site_retained_effect = NA,
    site_near_chance_or_worse = NA, site_robustness_status = "not evaluated",
    site_robustness_warning = paste(
      "TCGA tissue-source-site-grouped sensitivity has not yet been evaluated",
      "for this representation."
    ),
    site_grouped_validation_scope = "not evaluated",
    model_evidence_tier = fcase(
      job$outcome_type == "binary" && min(artifact$positive, artifact$negative) < 50,
        "exploratory_limited_evidence",
      job$outcome_type == "continuous" && length(y) < 100,
        "exploratory_limited_continuous_evidence",
      job$outcome_type == "continuous" && job$q2 >= 0.20,
        "matched_effect_threshold_internal_evidence",
      job$outcome_type == "binary" && job$auc >= 0.60,
        "matched_effect_threshold_internal_evidence",
      default = "matched_tested_below_effect_threshold"
    ),
    limited_evidence_reason = fcase(
      job$outcome_type == "binary" && min(artifact$positive, artifact$negative) < 50,
        "fewer than 50 patients in one or both binary classes",
      job$outcome_type == "continuous" && length(y) < 100,
        "fewer than 100 outcome-labelled patients",
      job$outcome_type == "continuous" && job$q2 < 0.20,
        "representation-specific matched Q2 was below the descriptive effect threshold",
      job$outcome_type == "binary" && job$auc < 0.60,
        "representation-specific matched AUROC was below the descriptive effect threshold",
      default = ""
    ),
    default_inference = if (job$outcome_type == "continuous")
      job$q2 >= 0.20 && length(y) >= 100 else
      job$auc >= 0.60 && min(artifact$positive, artifact$negative) >= 50,
    redistribution_status = paste(
      "optional public PathoFMPred download under separate CC BY 4.0",
      "downstream-asset terms; upstream notices remain applicable"
    )
  )]
  cat("Fitted", i, "of", nrow(jobs), model_id, "\n")
  flush.console()
  old
}

workers <- as.integer(Sys.getenv("TITAN_WORKERS", "4"))
future::plan(future::multicore, workers = workers)
registry_rows <- future_lapply(
  seq_len(nrow(jobs)), fit_resource_model, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table", "digest"),
  future.globals = TRUE, future.chunk.size = 1
)

registry <- rbindlist(registry_rows, fill = TRUE)
setcolorder(registry, union(c("foundation_model", "model_id"), names(registry)))
fwrite(registry, file.path(out_dir, "model_registry_additions.csv"))

oof <- oof[foundation_model %chin% c("GigaSSL", "ProvGigaPath")]
oof <- merge(oof, registry[, .(foundation_model, outcome_type, family,
                               tumor_type = cancer_type, endpoint, model_id)],
             by = c("foundation_model", "outcome_type", "family", "tumor_type", "endpoint"))
oof[, reference_value := fifelse(outcome_type == "continuous", predicted, score)]
reference <- oof[is.finite(reference_value), sort(reference_value),
                 by = .(foundation_model, model_id)]
reference_list <- split(reference$V1,
                        paste(reference$foundation_model, reference$model_id, sep = "::"))
saveRDS(reference_list, file.path(out_dir, "prediction_reference_additions.rds"),
        compress = "xz")

# Candidate membership can change after a synchronized permutation refresh.
# Remove only unregistered fitted-object files from this explicit resource
# directory; the prediction-reference object is retained separately.
registered_rds <- c(
  basename(registry$file), "prediction_reference_additions.rds"
)
existing_rds <- list.files(out_dir, pattern = "[.]rds$", full.names = TRUE)
stale_rds <- existing_rds[!basename(existing_rds) %chin% registered_rds]
if (length(stale_rds)) {
  removed <- unlink(stale_rds)
  if (any(removed != 0L)) {
    stop("Failed to remove one or more stale foundation-model artifacts")
  }
}
message("Removed ", length(stale_rds),
        " unregistered stale foundation-model artifacts")
