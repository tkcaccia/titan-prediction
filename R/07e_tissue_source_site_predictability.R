.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
backend <- tolower(Sys.getenv("TITAN_BACKEND", "cpu"))
options(fastPLS.backend = backend)

cohort <- readRDS("data/processed/patient_cohort.rds")
meta <- as.data.table(cohort$meta)
meta <- meta[
  !is.na(tumor_type) & nzchar(tumor_type) &
    !is.na(tissue_source_site) & nzchar(tissue_source_site)
]

# Ten patients per tissue-source site permits five-fold outer validation and
# leaves at least eight members of every retained site in each outer training
# set. Rare sites remain reported as excluded for this dedicated confounding
# analysis; they are not removed from any molecular-endpoint analysis.
minimum_patients_per_site <- 10L
repeats <- 5L
cancers <- sort(unique(meta$tumor_type))
workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
future::plan(future::multicore, workers = workers)

macro_f1 <- function(truth, estimate) {
  lev <- levels(truth)
  estimate <- factor(as.character(estimate), levels = lev)
  mean(vapply(lev, function(z) {
    tp <- sum(truth == z & estimate == z)
    fp <- sum(truth != z & estimate == z)
    fn <- sum(truth == z & estimate != z)
    denominator <- 2 * tp + fp + fn
    if (denominator == 0L) NA_real_ else 2 * tp / denominator
  }, numeric(1L)), na.rm = TRUE)
}

run_cancer <- function(i) {
  cancer <- cancers[[i]]
  d <- meta[tumor_type == cancer, .(patient, tissue_source_site)]
  counts <- d[, .N, by = tissue_source_site]
  eligible_sites <- counts[N >= minimum_patients_per_site, tissue_source_site]
  retained <- d[tissue_source_site %chin% eligible_sites]
  excluded_patients <- nrow(d) - nrow(retained)
  if (length(eligible_sites) < 2L) {
    return(list(
      repeats = NULL,
      summary = data.table(
        tumor_type = cancer, eligible = FALSE,
        total_patients = nrow(d), analysed_patients = nrow(retained),
        excluded_rare_site_patients = excluded_patients,
        total_sites = uniqueN(d$tissue_source_site),
        analysed_sites = length(eligible_sites),
        minimum_patients_per_site = minimum_patients_per_site,
        repeated_nested_cv = repeats,
        macro_balanced_accuracy_mean = NA_real_,
        macro_balanced_accuracy_sd = NA_real_,
        macro_f1_mean = NA_real_, accuracy_mean = NA_real_,
        majority_accuracy = NA_real_, chance_macro_balanced_accuracy = NA_real_,
        normalized_macro_balanced_accuracy = NA_real_,
        selected_components_median = NA_real_,
        error = "fewer than two tissue-source sites had at least 10 patients"
      )
    ))
  }
  idx <- match(retained$patient, rownames(cohort$X))
  X <- cohort$X[idx, , drop = FALSE]
  y <- factor(retained$tissue_source_site)
  seed <- cfg$analysis$seed + 500000L + i
  fit <- tryCatch(
    pls.double.cv(
      X, y, ncomp = cfg$analysis$components,
      classifier = "lda", lda_ridge = cfg$analysis$lda_ridge,
      selection_metric = "balanced_accuracy",
      kfold_outer = cfg$analysis$outer_folds,
      kfold_inner = cfg$analysis$inner_folds,
      runn = repeats, seed = seed,
      svd.method = cfg$analysis$svd_method,
      rsvd_oversample = cfg$analysis$rsvd_oversample,
      rsvd_power = cfg$analysis$rsvd_power,
      perm.test = FALSE
    ),
    error = function(e) e
  )
  if (inherits(fit, "error")) {
    return(list(
      repeats = NULL,
      summary = data.table(
        tumor_type = cancer, eligible = TRUE,
        total_patients = nrow(d), analysed_patients = nrow(retained),
        excluded_rare_site_patients = excluded_patients,
        total_sites = uniqueN(d$tissue_source_site),
        analysed_sites = nlevels(y),
        minimum_patients_per_site = minimum_patients_per_site,
        repeated_nested_cv = repeats,
        macro_balanced_accuracy_mean = NA_real_,
        macro_balanced_accuracy_sd = NA_real_,
        macro_f1_mean = NA_real_, accuracy_mean = NA_real_,
        majority_accuracy = max(prop.table(table(y))),
        chance_macro_balanced_accuracy = 1 / nlevels(y),
        normalized_macro_balanced_accuracy = NA_real_,
        selected_components_median = NA_real_,
        error = conditionMessage(fit)
      )
    ))
  }
  repeat_rows <- rbindlist(lapply(seq_len(repeats), function(r) {
    pred <- factor(as.character(fit$results[[r]]$Ypred), levels = levels(y))
    ba <- balanced_accuracy(y, pred)
    data.table(
      tumor_type = cancer, `repeat` = r,
      patients = length(y), sites = nlevels(y),
      macro_balanced_accuracy = ba,
      macro_f1 = macro_f1(y, pred),
      accuracy = mean(pred == y),
      chance_macro_balanced_accuracy = 1 / nlevels(y),
      normalized_macro_balanced_accuracy =
        (ba - 1 / nlevels(y)) / (1 - 1 / nlevels(y)),
      selected_components_median = median(fit$results[[r]]$best_ncomp),
      seed = seed + r - 1L,
      backend = backend, svd_method = cfg$analysis$svd_method,
      rsvd_oversample = cfg$analysis$rsvd_oversample,
      rsvd_power = cfg$analysis$rsvd_power
    )
  }))
  list(
    repeats = repeat_rows,
    summary = repeat_rows[, .(
      tumor_type = cancer, eligible = TRUE,
      total_patients = nrow(d), analysed_patients = nrow(retained),
      excluded_rare_site_patients = excluded_patients,
      total_sites = uniqueN(d$tissue_source_site),
      analysed_sites = nlevels(y),
      minimum_patients_per_site = minimum_patients_per_site,
      repeated_nested_cv = repeats,
      macro_balanced_accuracy_mean = mean(macro_balanced_accuracy),
      macro_balanced_accuracy_sd = sd(macro_balanced_accuracy),
      macro_f1_mean = mean(macro_f1), accuracy_mean = mean(accuracy),
      majority_accuracy = max(prop.table(table(y))),
      chance_macro_balanced_accuracy = 1 / nlevels(y),
      normalized_macro_balanced_accuracy = mean(normalized_macro_balanced_accuracy),
      selected_components_median = median(selected_components_median),
      error = NA_character_
    )]
  )
}

objects <- future_lapply(
  seq_along(cancers), run_cancer, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table")
)
repeat_table <- rbindlist(lapply(objects, `[[`, "repeats"), fill = TRUE)
summary_table <- rbindlist(lapply(objects, `[[`, "summary"), fill = TRUE)
setorderv(repeat_table, c("tumor_type", "repeat"))
setorder(summary_table, tumor_type)
fwrite(repeat_table, "results/tables/tissue_source_site_predictability_repeats.csv")
fwrite(summary_table, "results/tables/tissue_source_site_predictability_summary.csv")

failed <- summary_table[eligible == TRUE & !is.na(error)]
if (nrow(failed)) stop("Eligible tissue-source-site models failed: ", paste(failed$tumor_type, collapse = ", "))
cat("Tissue-source-site predictability evaluated in",
    summary_table[eligible == TRUE & is.na(error), .N], "of", nrow(summary_table),
    "cancers.\n")
