.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(glmnet)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()

models <- c("TITAN", "GigaSSL", "ProvGigaPath")
cohorts <- setNames(lapply(models, function(m) {
  readRDS(file.path("data/processed", paste0("patient_cohort_", m, ".rds")))
}), models)
common <- Reduce(intersect, lapply(cohorts, function(z) rownames(z$X)))
jobs <- fread("results/tables/pls_vs_ridge_representative_jobs.csv")
primary <- fread("results/tables/foundation_model_matched_screen.csv")
task_key <- c("outcome_type", "family", "tumor_type", "endpoint")
primary_tasks <- unique(primary[, ..task_key])
missing_matched_jobs <- jobs[!primary_tasks, on = task_key]
fwrite(
  missing_matched_jobs,
  "results/tables/foundation_model_ridge_probe_ineligible_jobs.csv"
)
jobs <- jobs[primary_tasks, on = task_key, nomatch = 0L]
setorder(jobs, outcome_type, family, tumor_type, endpoint)
if (!nrow(jobs)) stop("No representative probe jobs are eligible in the matched cohort")
continuous <- readRDS("data/processed/continuous_targets.rds")
binary <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), fill = TRUE)

average_precision <- function(truth, score) {
  y <- as.integer(as.character(truth)); o <- order(score, decreasing = TRUE)
  y <- y[o]; if (!sum(y == 1L) || !sum(y == 0L)) return(NA_real_)
  mean(cumsum(y)[y == 1L] / which(y == 1L))
}

best_ba_threshold <- function(y, score) {
  candidates <- c(-Inf, sort(unique(score)), Inf)
  ba <- vapply(candidates, function(z) balanced_accuracy(
    y, factor(as.integer(score >= z), levels = c(0L, 1L))
  ), numeric(1))
  best <- which(ba == max(ba, na.rm = TRUE))
  candidates[best[which.min(abs(candidates[best] - median(score)))]]
}

ridge_nested <- function(X, y, binary_outcome, seed) {
  outer <- if (binary_outcome) stratified_folds(y, cfg$analysis$outer_folds, seed) else
    random_folds(length(y), cfg$analysis$outer_folds, seed)
  score <- rep(NA_real_, length(y)); pred <- rep(NA_real_, length(y))
  lambdas <- numeric(cfg$analysis$outer_folds); failures <- 0L
  for (fold in seq_len(cfg$analysis$outer_folds)) {
    test <- outer == fold; train <- !test
    inner <- if (binary_outcome) stratified_folds(y[train], cfg$analysis$inner_folds, seed + 1000L + fold) else
      random_folds(sum(train), cfg$analysis$inner_folds, seed + 1000L + fold)
    family <- if (binary_outcome) "binomial" else "gaussian"
    fit <- tryCatch(cv.glmnet(X[train,,drop=FALSE], if (binary_outcome) as.integer(as.character(y[train])) else y[train],
      family = family, alpha = 0, foldid = inner, keep = TRUE, standardize = TRUE,
      type.measure = if (binary_outcome) "auc" else "mse"), error = identity)
    if (inherits(fit, "error")) { failures <- failures + 1L; next }
    if (binary_outcome) {
      inner_score <- plogis(fit$fit.preval)
      inner_auc <- apply(inner_score, 2, function(s) rank_auc(y[train], s))
      k <- which.max(inner_auc)
      threshold <- best_ba_threshold(y[train], inner_score[, k])
      score[test] <- as.numeric(predict(fit$glmnet.fit, X[test,,drop=FALSE], s=fit$lambda[k], type="response"))
      pred[test] <- as.integer(score[test] >= threshold)
    } else {
      inner_pred <- as.matrix(fit$fit.preval)
      k <- which.max(apply(inner_pred, 2, function(p) q_squared(y[train], p)))
      pred[test] <- as.numeric(predict(fit$glmnet.fit, X[test,,drop=FALSE], s=fit$lambda[k]))
    }
    lambdas[fold] <- fit$lambda[k]
  }
  complete <- is.finite(pred)
  if (!all(complete)) return(list(failure_count=failures, q2=NA, ba=NA, auc=NA, pr_auc=NA, lambda=NA))
  if (binary_outcome) {
    m <- binary_classification_metrics(y, factor(pred, levels=c(0L,1L)), score)
    list(failure_count=failures, q2=NA_real_, ba=m$balanced_accuracy, auc=m$auc,
         pr_auc=average_precision(y, score), lambda=median(lambdas))
  } else list(failure_count=failures, q2=q_squared(y,pred), ba=NA_real_, auc=NA_real_,
              pr_auc=NA_real_, lambda=median(lambdas))
}

run_one_job <- function(j) {
  job <- jobs[j]; targets <- if (job$outcome_type == "binary") binary else continuous
  d <- targets[family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint & patient %chin% common]
  setorder(d, patient)
  y <- if (job$outcome_type == "binary") factor(d$value, levels=c(0L,1L)) else d$value
  seed_values <- unique(primary[
    outcome_type == job$outcome_type & family == job$family &
      tumor_type == job$tumor_type & endpoint == job$endpoint, seed
  ])
  if (length(seed_values) != 1L) stop("Could not resolve the primary atlas seed")
  seed <- as.integer(seed_values)
  rows <- lapply(models, function(model) {
    idx <- match(d$patient, rownames(cohorts[[model]]$X)); X <- cohorts[[model]]$X[idx,,drop=FALSE]
    z <- ridge_nested(X, y, job$outcome_type == "binary", seed)
    cbind(job[,.(outcome_type,family,tumor_type,endpoint,size_stratum,imbalance_stratum,n)],
                          data.table(foundation_model=model, ridge_q2=z$q2,
                          ridge_balanced_accuracy=z$ba, ridge_auc=z$auc,
                          ridge_pr_auc=z$pr_auc, ridge_lambda_median=z$lambda,
                          numerical_failures=z$failure_count))
  })
  cat("Completed", j, "of", nrow(jobs), "ridge-probe targets\n")
  rbindlist(rows, fill=TRUE)
}
workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
if (workers > 1L) future::plan(future::multicore, workers=workers)
results <- future_lapply(seq_len(nrow(jobs)), run_one_job, future.seed=TRUE,
                         future.packages=c("data.table","glmnet"))
ridge <- rbindlist(results, fill=TRUE)
fwrite(ridge, "results/tables/foundation_model_ridge_probe_subset.csv")

audit <- primary[, .(
  targets=.N,
  selected_components_median=as.numeric(median(selected_components_median)),
  targets_with_any_outer_fit_at_ceiling=sum(selected_components_max == max(cfg$analysis$components)),
  target_ceiling_percent=100*mean(selected_components_max == max(cfg$analysis$components)),
  outer_fits_at_ceiling=if ("selected_components_at_ceiling" %in% names(primary)) sum(selected_components_at_ceiling) else NA_integer_,
  outer_fits_total=if ("selected_components_outer_fits" %in% names(primary)) sum(selected_components_outer_fits) else NA_integer_,
  outer_fit_ceiling_percent=if ("selected_components_at_ceiling" %in% names(primary)) 100*sum(selected_components_at_ceiling)/sum(selected_components_outer_fits) else NA_real_,
  numerical_failures=0L
), by=.(foundation_model,outcome_type)]
variance <- rbindlist(lapply(models, function(m) {
  X <- cohorts[[m]]$X[common,,drop=FALSE]; s <- apply(X,2,sd)
  data.table(foundation_model=m, dimensions=ncol(X), constant_features=sum(s == 0),
             near_constant_features=sum(s > 0 & s <= 1e-8),
             variance_filtering="none before nested fitting; glmnet standardises within training folds")
}))
fwrite(audit, "results/tables/foundation_model_pls_component_audit.csv")
fwrite(variance, "results/tables/foundation_model_feature_variance_audit.csv")

metric <- ifelse(ridge$outcome_type == "binary", ridge$ridge_auc, ridge$ridge_q2)
ridge[, effect := metric]
ridge_rank <- ridge[, .SD[which.max(effect)], by=.(outcome_type,family,tumor_type,endpoint)][,
  .(outcome_type,family,tumor_type,endpoint,ridge_winner=foundation_model,ridge_best_effect=effect)]
pls <- primary[, effect := fifelse(outcome_type=="binary", auc, q2)][,
  .SD[which.max(effect)], by=.(outcome_type,family,tumor_type,endpoint)][,
  .(outcome_type,family,tumor_type,endpoint,pls_winner=foundation_model,pls_best_effect=effect)]
comparison <- merge(ridge_rank, pls, by=c("outcome_type","family","tumor_type","endpoint"))
comparison[, winner_retained := ridge_winner == pls_winner]
fwrite(comparison, "results/tables/foundation_model_probe_ranking_sensitivity.csv")
fwrite(comparison[,.(targets=.N,winner_retained=sum(winner_retained),
                    winner_retained_percent=100*mean(winner_retained)),by=outcome_type],
       "results/tables/foundation_model_probe_ranking_summary.csv")
