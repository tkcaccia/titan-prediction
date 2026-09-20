.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
options(backend = tolower(Sys.getenv("TITAN_BACKEND", "cpu")))

cohort <- readRDS("data/processed/patient_cohort.rds")
continuous_targets <- readRDS("data/processed/continuous_targets.rds")
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names=TRUE)
continuous_jobs <- fread("results/tables/continuous_screen.csv")[tier %chin% c("A","B")]
binary_jobs <- fread("results/tables/binary_screen.csv")[tier %chin% c("A","B")]
make_folds <- getFromNamespace(".make_single_cv_folds", "fastPLS")

matched_outer <- function(grouped, y, binary, seed) {
  set.seed(seed)
  out <- integer(length(grouped))
  if (binary) {
    for (lev in levels(y)) {
      idx <- sample(which(y == lev))
      counts <- table(factor(grouped[y == lev], levels=sort(unique(grouped))))
      cursor <- 1L
      for (f in seq_along(counts)) {
        if (counts[[f]] > 0L) {
          take <- idx[cursor:(cursor + counts[[f]] - 1L)]
          out[take] <- as.integer(names(counts)[[f]])
          cursor <- cursor + counts[[f]]
        }
      }
    }
  } else {
    idx <- sample(seq_along(grouped)); counts <- table(grouped); cursor <- 1L
    for (f in seq_along(counts)) {
      take <- idx[cursor:(cursor + counts[[f]] - 1L)]
      out[take] <- as.integer(names(counts)[[f]])
      cursor <- cursor + counts[[f]]
    }
  }
  out
}

fit_custom <- function(X, y, site, outer, grouped_inner, binary, seed) {
  pred <- if (binary) factor(rep(NA_character_, length(y)), levels=levels(y)) else rep(NA_real_, length(y))
  score <- rep(NA_real_, length(y)); ncomp <- integer(length(unique(outer)))
  folds <- sort(unique(outer))
  for (ff in seq_along(folds)) {
    test <- outer == folds[[ff]]; train <- !test
    cv <- fastPLS::pls.single.cv(
      X[train,,drop=FALSE], y[train], ncomp=cfg$analysis$components,
      constrain=if (grouped_inner) site[train] else NULL,
      kfold=cfg$analysis$inner_folds,
      classifier = if (binary) "lda" else "argmax",
      selection = if (binary) "balanced_accuracy" else "Q2Y",
      rsvd_oversample = cfg$analysis$rsvd_oversample,
      rsvd_power=cfg$analysis$rsvd_power, seed=seed + 2000L + ff, fit=FALSE
    )
    ncomp[[ff]] <- cv$best_ncomp
    fit <- fastPLS::pls(
      X[train,,drop=FALSE], y[train], ncomp=ncomp[[ff]],
      classifier=if (binary) "lda" else "argmax", fit=TRUE, return_loadings=TRUE, rsvd_oversample=cfg$analysis$rsvd_oversample,
      rsvd_power=cfg$analysis$rsvd_power, seed=seed + 3000L + ff
    )
    z <- predict(fit, X[test,,drop=FALSE], raw_scores=binary)
    if (binary) {
      pred[test] <- z$Ypred[[1L]]
      score[test] <- drop(z$LDA_scores[,2L,1L] - z$LDA_scores[,1L,1L])
    } else pred[test] <- as.numeric(drop(z$Ypred))
  }
  list(pred=pred, score=score, ncomp=ncomp)
}

site_only_oof <- function(y, site, binary, seed) {
  fold <- if (binary) stratified_folds(y, cfg$analysis$outer_folds, seed) else
    random_folds(length(y), cfg$analysis$outer_folds, seed)
  pred <- rep(NA_real_, length(y))
  for (f in sort(unique(fold))) {
    test <- fold == f; train <- !test
    global <- if (binary) mean(as.integer(as.character(y[train]))) else mean(y[train])
    means <- data.table(site=site[train], value=if (binary) as.integer(as.character(y[train])) else y[train])[,.(m=mean(value)),by=site]
    pred[test] <- means$m[match(site[test], means$site)]
    pred[test][!is.finite(pred[test])] <- global
  }
  pred
}

bootstrap_delta <- function(y, grouped_pred, matched_pred, grouped_score, matched_score, binary, seed, B=1000L) {
  metric <- function(idx, pred, score) if (binary) {
    balanced_accuracy(y[idx], factor(as.character(pred[idx]), levels=levels(y)))
  } else q_squared(y[idx], pred[idx])
  point <- metric(seq_along(y), grouped_pred, grouped_score) - metric(seq_along(y), matched_pred, matched_score)
  set.seed(seed)
  b <- replicate(B, {
    idx <- sample.int(length(y), length(y), replace=TRUE)
    metric(idx, grouped_pred, grouped_score) - metric(idx, matched_pred, matched_score)
  })
  c(point=point, low=quantile(b,.025,na.rm=TRUE), high=quantile(b,.975,na.rm=TRUE))
}

run_job <- function(job, i, binary=FALSE) {
  targets <- if (binary) binary_targets else continuous_targets
  d <- targets[family==job$family & tumor_type==job$tumor_type & endpoint==job$endpoint]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx) & if (binary) d$value %in% c(0L,1L) else is.finite(d$value)
  d <- d[keep]; setorder(d, patient); idx <- match(d$patient, rownames(cohort$X))
  X <- cohort$X[idx,,drop=FALSE]
  y <- if (binary) factor(d$value, levels=c(0L,1L)) else d$value
  site <- substr(d$patient,6L,7L); seed <- cfg$analysis$seed + i
  grouped_outer <- make_folds(Ydata=y, constrain=site, kfold=cfg$analysis$outer_folds, seed=seed)
  matched <- matched_outer(grouped_outer, y, binary, seed + 900000L)
  context <- paste(
    if (binary) "binary" else "continuous", job$family,
    job$tumor_type, job$endpoint, sep = " | "
  )
  g <- tryCatch(
    fit_custom(X,y,site,grouped_outer,TRUE,binary,seed),
    error = function(e) stop(
      "Grouped partition failed for ", context, ": ", conditionMessage(e),
      call. = FALSE
    )
  )
  m <- tryCatch(
    fit_custom(X,y,site,matched,FALSE,binary,seed),
    error = function(e) stop(
      "Matched-random partition failed for ", context, ": ",
      conditionMessage(e), call. = FALSE
    )
  )
  interval <- bootstrap_delta(y,g$pred,m$pred,g$score,m$score,binary,seed+800000L)
  code_score <- site_only_oof(y,site,binary,seed+700000L)
  site_stats <- data.table(site=site, value=if(binary) as.integer(as.character(y)) else y)[,
    .(n=.N, mean=mean(value), sd=if(.N>1) sd(value) else NA_real_),by=site]
  heterogeneity <- if (binary) max(site_stats$mean)-min(site_stats$mean) else
    sum(site_stats$n*(site_stats$mean-mean(y))^2)/sum((y-mean(y))^2)
  stable_sites <- site_stats[n >= 5L]
  heterogeneity_min5 <- if (nrow(stable_sites) < 2L) NA_real_ else if (binary) {
    max(stable_sites$mean) - min(stable_sites$mean)
  } else {
    sum(stable_sites$n*(stable_sites$mean-weighted.mean(stable_sites$mean,stable_sites$n))^2) /
      sum((y[site %chin% stable_sites$site]-mean(y[site %chin% stable_sites$site]))^2)
  }
  code_metric <- if (binary) rank_auc(y,code_score) else q_squared(y,code_score)
  data.table(
    outcome_type=if(binary) "binary" else "continuous", family=job$family,
    tumor_type=job$tumor_type, endpoint=job$endpoint, n=length(y), n_codes=uniqueN(site),
    grouped_metric=if(binary) balanced_accuracy(y,g$pred) else q_squared(y,g$pred),
    matched_random_metric=if(binary) balanced_accuracy(y,m$pred) else q_squared(y,m$pred),
    grouped_minus_matched=interval[["point"]], paired_ci_low=interval[["low.2.5%"]],
    paired_ci_high=interval[["high.97.5%"]], bootstrap_resamples=1000L,
    code_only_metric=code_metric,
    code_heterogeneity=heterogeneity,
    code_heterogeneity_minimum5=heterogeneity_min5,
    minimum_prevalence_minimum5=if(binary && nrow(stable_sites)) min(stable_sites$mean) else NA_real_,
    maximum_prevalence_minimum5=if(binary && nrow(stable_sites)) max(stable_sites$mean) else NA_real_,
    codes_with_minimum5=nrow(stable_sites), minimum_code_n=min(site_stats$n),
    maximum_code_n=max(site_stats$n),
    heterogeneity_definition=if(binary) "maximum minus minimum code-specific outcome prevalence" else "eta-squared: between-code sum of squares / total sum of squares",
    exact_outer_test_sizes_matched=identical(sort(as.integer(table(grouped_outer))),sort(as.integer(table(matched)))),
    exact_outer_class_counts_matched=if(binary) all(table(grouped_outer,y)==table(matched,y)) else NA,
    grouped_components_median=median(g$ncomp), matched_components_median=median(m$ncomp),
    seed=seed
  )
}

workers <- as.integer(Sys.getenv("TITAN_WORKERS","6")); future::plan(future::multicore, workers=workers)
crows <- future_lapply(seq_len(nrow(continuous_jobs)), function(i) run_job(continuous_jobs[i],i,FALSE),
                       future.seed=TRUE, future.packages=c("fastPLS","data.table"))
brows <- future_lapply(seq_len(nrow(binary_jobs)), function(i) run_job(binary_jobs[i],i,TRUE),
                       future.seed=TRUE, future.packages=c("fastPLS","data.table"))
out <- rbindlist(c(crows,brows),fill=TRUE)
setorder(out,outcome_type,family,tumor_type,endpoint)
fwrite(out,"results/tables/tissue_source_site_partition_controls.csv")
summary <- out[,.(models=.N,median_grouped_minus_matched=median(grouped_minus_matched),
  q1=quantile(grouped_minus_matched,.25),q3=quantile(grouped_minus_matched,.75),
  intervals_below_zero=sum(paired_ci_high<0),intervals_include_zero=sum(paired_ci_low<=0 & paired_ci_high>=0),
  median_code_only_metric=median(code_only_metric),median_code_heterogeneity=median(code_heterogeneity),
  exact_size_matches=sum(exact_outer_test_sizes_matched),exact_class_matches=if(outcome_type[[1]]=="binary")sum(exact_outer_class_counts_matched) else NA_integer_),
  by=outcome_type]
fwrite(summary,"results/tables/tissue_source_site_partition_controls_summary.csv")
print(summary)
