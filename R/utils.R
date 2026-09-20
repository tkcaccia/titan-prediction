project_root <- function() {
  wd <- normalizePath(getwd(), mustWork = TRUE)
  if (file.exists(file.path(wd, "config", "analysis.R"))) return(wd)
  stop("Run scripts from the titan-prediction repository root.")
}

load_project_config <- function() {
  root <- project_root()
  source(file.path(root, "config", "analysis.R"), local = FALSE)
  local_path <- file.path(root, "config", "paths.local.R")
  example_path <- file.path(root, "config", "paths.example.R")
  source(if (file.exists(local_path)) local_path else example_path, local = FALSE)
  list(root = root, analysis = analysis_config, paths = paths)
}

assert_files <- function(x) {
  missing <- names(x)[!file.exists(unlist(x))]
  if (length(missing)) {
    stop("Missing configured source files: ", paste(missing, collapse = ", "))
  }
  invisible(TRUE)
}

safe_name <- function(...) {
  x <- paste(..., sep = "__")
  gsub("[^A-Za-z0-9_.-]+", "_", x)
}

continuous_endpoint_transform <- function(family, endpoint) {
  n <- max(length(family), length(endpoint))
  family <- rep_len(as.character(family), n)
  endpoint <- rep_len(as.character(endpoint), n)
  thorsson_log1p <- c(
    "Nonsilent Mutation Rate", "Silent Mutation Rate", "SNV Neoantigens",
    "Indel Neoantigens", "Number of Segments"
  )
  out <- rep("none", n)
  out[(family == "thorsson" & endpoint %in% thorsson_log1p) |
        (family == "fusion" & endpoint == "Fusion burden")] <- "log1p"
  out
}

balanced_accuracy <- function(truth, estimate) {
  truth <- factor(truth)
  estimate <- factor(estimate, levels = levels(truth))
  tab <- table(truth, estimate)
  mean(diag(tab) / rowSums(tab))
}

binary_classification_metrics <- function(truth, estimate, score = NULL) {
  truth <- factor(as.character(truth), levels = c("0", "1"))
  estimate <- factor(as.character(estimate), levels = levels(truth))
  tab <- table(truth, estimate)
  sensitivity <- if (sum(tab["1", ]) > 0L) {
    tab["1", "1"] / sum(tab["1", ])
  } else NA_real_
  specificity <- if (sum(tab["0", ]) > 0L) {
    tab["0", "0"] / sum(tab["0", ])
  } else NA_real_
  ppv <- if (sum(tab[, "1"]) > 0L) {
    tab["1", "1"] / sum(tab[, "1"])
  } else NA_real_
  npv <- if (sum(tab[, "0"]) > 0L) {
    tab["0", "0"] / sum(tab[, "0"])
  } else NA_real_
  prevalence <- mean(truth == "1")
  data.table::data.table(
    sensitivity = as.numeric(sensitivity),
    specificity = as.numeric(specificity),
    ppv = as.numeric(ppv),
    npv = as.numeric(npv),
    balanced_accuracy = mean(c(sensitivity, specificity), na.rm = TRUE),
    auc = if (is.null(score)) NA_real_ else rank_auc(truth, score),
    prevalence = as.numeric(prevalence),
    no_skill_pr_auc = as.numeric(prevalence)
  )
}

rank_auc <- function(truth, score, positive = "1") {
  y <- as.character(truth) == positive
  n1 <- sum(y); n0 <- sum(!y)
  if (!n1 || !n0) return(NA_real_)
  (sum(rank(score, ties.method = "average")[y]) - n1 * (n1 + 1) / 2) /
    (n1 * n0)
}

average_precision <- function(truth, score, positive = "1") {
  truth <- as.character(truth)
  keep <- truth %in% c("0", "1") & is.finite(score)
  truth <- truth[keep]
  score <- score[keep]
  is_positive <- truth == positive
  n_positive <- sum(is_positive)
  if (!n_positive || !sum(!is_positive)) return(NA_real_)
  z <- data.table::data.table(score = score, positive = is_positive)[, .(
    positives = sum(positive), total = .N
  ), by = score]
  data.table::setorder(z, -score)
  z[, `:=`(cum_pos = cumsum(positives), cum_n = cumsum(total))]
  sum((z$positives / n_positive) * (z$cum_pos / z$cum_n))
}

# Select an operating threshold using training-only out-of-fold scores. Exact
# balanced-accuracy ties prefer a finite threshold and then the value closest
# to the supplied reference, matching the symmetric PLS-versus-ridge audit.
best_balanced_threshold <- function(truth, score, reference = 0) {
  truth <- factor(as.character(truth), levels = c("0", "1"))
  keep <- !is.na(truth) & is.finite(score)
  truth <- truth[keep]
  score <- score[keep]
  if (length(unique(truth)) < 2L || !length(score)) {
    return(list(threshold = reference, balanced_accuracy = NA_real_))
  }
  # For a finite threshold t, all observations with score >= t are positive.
  # Aggregate tied scores once and scan from the highest score downward. This
  # is exactly equivalent to evaluating every unique threshold separately but
  # avoids a quadratic loop for large cohorts.
  z <- data.table::data.table(
    score = score,
    positive = as.character(truth) == "1"
  )[, .(positive = sum(positive), negative = sum(!positive)), by = score]
  data.table::setorder(z, score)
  true_positive <- rev(cumsum(rev(z$positive)))
  false_positive <- rev(cumsum(rev(z$negative)))
  n_positive <- sum(z$positive)
  n_negative <- sum(z$negative)
  finite_ba <- 0.5 * (
    true_positive / n_positive + (n_negative - false_positive) / n_negative
  )
  candidates <- c(-Inf, z$score, Inf)
  ba <- c(0.5, finite_ba, 0.5)
  best <- which(abs(ba - max(ba, na.rm = TRUE)) <= 1e-12)
  finite_best <- best[is.finite(candidates[best])]
  if (length(finite_best)) best <- finite_best
  distance <- abs(candidates[best] - reference)
  chosen <- best[which.min(distance)]
  list(threshold = candidates[chosen], balanced_accuracy = ba[chosen])
}

# Extract the positive-versus-negative PLS-LDA discriminant-score contrast for
# one latent-component count. The score remains uncalibrated and is used for
# ranking (AUROC/PR-AUC) and for training-only threshold selection.
binary_score_contrast <- function(prediction, component) {
  scores <- prediction$LDA_scores
  component_index <- match(component, as.integer(dimnames(scores)[[3L]]))
  if (is.na(component_index)) component_index <- component
  drop(scores[, 2L, component_index] - scores[, 1L, component_index])
}

fit_binary_score_path <- function(Xtrain, ytrain, Xtest, cfg, seed) {
  fit <- fastPLS::pls(
    Xtrain, ytrain, ncomp = cfg$components,
    classifier = "lda", fit = TRUE, return_loadings = FALSE, rsvd_oversample = cfg$rsvd_oversample,
    rsvd_power = cfg$rsvd_power,
    seed = seed
  )
  list(fit = fit, prediction = predict(fit, Xtest, raw_scores = TRUE))
}

# Select the component count by pooled inner out-of-fold AUROC and then choose
# an operating threshold from those same training-only scores by maximising
# balanced accuracy. Exact AUROC ties select the smallest component count.
select_binary_auroc_rule <- function(X, y, outer_train, cfg, seed,
                                     constrain = NULL) {
  y <- factor(as.character(y), levels = c("0", "1"))
  X_outer <- X[outer_train, , drop = FALSE]
  y_outer <- y[outer_train]
  if (length(unique(y_outer)) < 2L) stop("Binary outer training set has one class")
  # A minority count of one no longer forces an invalid one-fold CV request.
  # fastPLS 0.3 handles the resulting one-class training fold with its
  # documented constant-class fallback and records that event explicitly.
  inner_k <- min(cfg$inner_folds, max(2L, min(table(y_outer))))
  inner <- fastPLS::pls.single.cv(
    Xdata = X_outer,
    Ydata = y_outer,
    ncomp = cfg$components,
    constrain = if (is.null(constrain)) seq_along(y_outer) else
      constrain[outer_train],
    kfold = inner_k,
    seed = seed,
    classifier = "lda",
    selection = "AUROC",
    fit = FALSE,
    return_splits = TRUE,
    rsvd_oversample = cfg$rsvd_oversample,
    rsvd_power = cfg$rsvd_power
  )
  score_path <- vapply(seq_along(cfg$components), function(index) {
    drop(inner$lda_scores[, 2L, index] - inner$lda_scores[, 1L, index])
  }, numeric(nrow(X_outer)))
  colnames(score_path) <- as.character(cfg$components)
  auc_path <- as.numeric(inner$selection_values)
  if (all(!is.finite(auc_path))) stop("No finite inner AUROC values")
  component <- as.integer(inner$best_ncomp)
  selected <- match(component, cfg$components)
  threshold <- best_balanced_threshold(
    y_outer, score_path[, as.character(component)], reference = 0
  )
  list(
    component = component,
    inner_auroc = auc_path[[selected]],
    inner_auroc_path = auc_path,
    threshold = threshold$threshold,
    inner_balanced_accuracy = threshold$balanced_accuracy,
    inner_folds = data.table::uniqueN(inner$fold),
    training_class_counts = inner$training_class_counts,
    degenerate_inner_folds = as.integer(inner$degenerate_inner_folds),
    constant_classifier_fallback = isTRUE(inner$constant_classifier_fallback),
    minimum_negative_training_count = as.integer(inner$minimum_negative_training_count),
    minimum_positive_training_count = as.integer(inner$minimum_positive_training_count),
    component_selection_informative = isTRUE(inner$component_selection_informative)
  )
}

# Nested binary evaluation aligned to one estimand: component tuning by inner
# AUROC, outer AUROC as the primary statistic, and secondary operating metrics
# at a threshold learned only from inner out-of-fold training scores.
fit_binary_nested_auroc_once <- function(X, y, cfg, seed, outer = NULL,
                                         inner_constrain = NULL) {
  y <- factor(as.character(y), levels = c("0", "1"))
  if (is.null(outer)) outer <- stratified_folds(y, cfg$outer_folds, seed)
  outer_values <- sort(unique(outer))
  score <- rep(NA_real_, length(y))
  call <- empirical_call <- equal_call <- rep(NA_integer_, length(y))
  selected <- integer(length(outer_values))
  threshold <- equal_threshold <- inner_auc <- rep(NA_real_, length(outer_values))
  inner_ba <- rep(NA_real_, length(outer_values))
  inner_folds <- integer(length(outer_values))
  degenerate_inner_folds <- vector("list", length(outer_values))
  constant_classifier_fallback <- logical(length(outer_values))
  minimum_negative_training_count <- minimum_positive_training_count <-
    rep(NA_integer_, length(outer_values))
  component_selection_informative <- logical(length(outer_values))
  outer_fit_estimable <- logical(length(outer_values))
  for (position in seq_along(outer_values)) {
    test <- outer == outer_values[[position]]
    train <- !test
    if (length(unique(y[train])) < 2L) {
      observed_class <- as.integer(as.character(y[train][[1L]]))
      fold_score <- rep(if (observed_class == 1L) 1 else -1, sum(test))
      score[test] <- fold_score
      call[test] <- empirical_call[test] <- equal_call[test] <- observed_class
      selected[[position]] <- 0L
      threshold[[position]] <- equal_threshold[[position]] <- 0
      inner_ba[[position]] <- 0.5
      inner_folds[[position]] <- 0L
      degenerate_inner_folds[[position]] <- NA_integer_
      constant_classifier_fallback[[position]] <- TRUE
      component_selection_informative[[position]] <- FALSE
      outer_fit_estimable[[position]] <- FALSE
      next
    }
    rule <- select_binary_auroc_rule(
      X, y, train, cfg, seed + position, constrain = inner_constrain
    )
    z <- fit_binary_score_path(
      X[train, , drop = FALSE], y[train], X[test, , drop = FALSE], cfg,
      seed = seed + 100L + position
    )
    fold_score <- binary_score_contrast(z$prediction, rule$component)
    lda_model <- z$fit$lda$models[[as.character(rule$component)]]
    priors <- as.numeric(lda_model$priors)
    fold_equal_threshold <- log(priors[[2L]] / priors[[1L]])
    score[test] <- fold_score
    call[test] <- as.integer(fold_score >= rule$threshold)
    empirical_call[test] <- as.integer(fold_score >= 0)
    equal_call[test] <- as.integer(fold_score >= fold_equal_threshold)
    selected[[position]] <- rule$component
    threshold[[position]] <- rule$threshold
    equal_threshold[[position]] <- fold_equal_threshold
    inner_auc[[position]] <- rule$inner_auroc
    inner_ba[[position]] <- rule$inner_balanced_accuracy
    inner_folds[[position]] <- rule$inner_folds
    degenerate_inner_folds[[position]] <- rule$degenerate_inner_folds
    constant_classifier_fallback[[position]] <- rule$constant_classifier_fallback
    minimum_negative_training_count[[position]] <-
      rule$minimum_negative_training_count
    minimum_positive_training_count[[position]] <-
      rule$minimum_positive_training_count
    component_selection_informative[[position]] <-
      rule$component_selection_informative
    outer_fit_estimable[[position]] <- TRUE
  }
  prediction <- factor(call, levels = c(0L, 1L))
  metrics <- binary_classification_metrics(y, prediction, score)
  list(
    prediction = prediction,
    empirical_prediction = factor(empirical_call, levels = c(0L, 1L)),
    equal_prediction = factor(equal_call, levels = c(0L, 1L)),
    score = score,
    fold = outer,
    ncomp = selected,
    threshold = threshold,
    equal_threshold = equal_threshold,
    inner_auc = inner_auc,
    inner_balanced_accuracy = inner_ba,
    inner_folds = inner_folds,
    degenerate_inner_folds = degenerate_inner_folds,
    constant_classifier_fallback = constant_classifier_fallback,
    minimum_negative_training_count = minimum_negative_training_count,
    minimum_positive_training_count = minimum_positive_training_count,
    component_selection_informative = component_selection_informative,
    outer_fit_estimable = outer_fit_estimable,
    balanced_accuracy = metrics$balanced_accuracy,
    auc = metrics$auc
  )
}

q_squared <- function(truth, estimate) {
  1 - sum((truth - estimate)^2) / sum((truth - mean(truth))^2)
}

mean_repeat_continuous_metrics <- function(d) {
  d <- data.table::as.data.table(d)
  per_repeat <- d[, .(
    q2 = q_squared(observed, predicted),
    rmse = sqrt(mean((observed - predicted)^2)),
    spearman = suppressWarnings(cor(observed, predicted, method = "spearman"))
  ), by = `repeat`]
  per_repeat[, .(
    q2 = mean(q2), rmse = mean(rmse), spearman = mean(spearman)
  )]
}

mean_repeat_binary_metrics <- function(d) {
  d <- data.table::as.data.table(d)
  per_repeat <- d[, binary_classification_metrics(
    factor(observed, levels = c(0L, 1L)),
    factor(predicted, levels = c(0L, 1L)),
    lda_score
  ), by = `repeat`]
  per_repeat[, .(
    sensitivity = mean(sensitivity), specificity = mean(specificity),
    balanced_accuracy = mean(balanced_accuracy), auc = mean(auc)
  )]
}

stratified_folds <- function(y, k, seed) {
  set.seed(seed)
  out <- integer(length(y))
  for (lev in unique(as.character(y))) {
    idx <- which(as.character(y) == lev)
    out[idx] <- sample(rep(seq_len(k), length.out = length(idx)))
  }
  out
}

random_folds <- function(n, k, seed) {
  set.seed(seed)
  sample(rep(seq_len(k), length.out = n))
}

fit_binary_nested_once <- function(X, y, cfg, seed) {
  y <- factor(as.character(y), levels = c("0", "1"))
  outer <- stratified_folds(y, cfg$outer_folds, seed)
  pred <- factor(rep(NA_character_, length(y)), levels = levels(y))
  score <- rep(NA_real_, length(y))
  selected <- integer(cfg$outer_folds)
  for (fold in seq_len(cfg$outer_folds)) {
    test <- outer == fold
    train <- !test
    inner_k <- min(cfg$inner_folds, min(table(y[train])))
    inner <- fastPLS::pls.single.cv(
      X[train, , drop = FALSE], y[train], ncomp = cfg$components,
      kfold = inner_k, seed = seed + fold, classifier = "lda", selection = "balanced_accuracy", rsvd_oversample = cfg$rsvd_oversample,
      rsvd_power = cfg$rsvd_power, fit = FALSE
    )
    selected[fold] <- inner$best_ncomp
    fit <- fastPLS::pls(
      X[train, , drop = FALSE], y[train], ncomp = selected[fold],
      classifier = "lda", fit = TRUE,
      return_loadings = TRUE, rsvd_oversample = cfg$rsvd_oversample,
      rsvd_power = cfg$rsvd_power,
      seed = seed + 100L + fold
    )
    z <- predict(fit, X[test, , drop = FALSE], raw_scores = TRUE)
    pred[test] <- z$Ypred[[1]]
    s <- drop(z$LDA_scores[, 2, 1] - z$LDA_scores[, 1, 1])
    score[test] <- s
  }
  list(
    prediction = pred,
    score = score,
    fold = outer,
    ncomp = selected,
    balanced_accuracy = balanced_accuracy(y, pred),
    auc = rank_auc(y, score)
  )
}

fit_continuous_nested_once <- function(X, y, cfg, seed) {
  outer <- random_folds(length(y), cfg$outer_folds, seed)
  pred <- rep(NA_real_, length(y))
  selected <- integer(cfg$outer_folds)
  for (fold in seq_len(cfg$outer_folds)) {
    test <- outer == fold
    train <- !test
    inner <- fastPLS::pls.single.cv(
      X[train, , drop = FALSE], y[train], ncomp = cfg$components,
      kfold = cfg$inner_folds, seed = seed + fold, rsvd_oversample = cfg$rsvd_oversample,
      rsvd_power = cfg$rsvd_power, fit = FALSE
    )
    selected[fold] <- inner$best_ncomp
    fit <- fastPLS::pls(
      X[train, , drop = FALSE], y[train], ncomp = selected[fold],
      fit = TRUE, return_loadings = TRUE, rsvd_oversample = cfg$rsvd_oversample,
      rsvd_power = cfg$rsvd_power,
      seed = seed + 100L + fold
    )
    # Continuous fastPLS predictions are returned as an n x 1 x 1 array.
    # Using [[1]] extracts one scalar and silently recycles it across the
    # complete test fold. Drop only singleton dimensions and require exactly
    # one prediction per held-out patient.
    fold_pred <- as.numeric(drop(
      predict(fit, X[test, , drop = FALSE])$Ypred
    ))
    if (length(fold_pred) != sum(test)) {
      stop(
        "Continuous prediction length mismatch: expected ", sum(test),
        ", received ", length(fold_pred)
      )
    }
    pred[test] <- fold_pred
  }
  list(
    prediction = pred,
    fold = outer,
    ncomp = selected,
    q2 = q_squared(y, pred),
    rmse = sqrt(mean((y - pred)^2)),
    correlation = suppressWarnings(cor(y, pred, method = "spearman"))
  )
}

fit_final_model <- function(X, y, outcome_type, ncomp, cfg, seed) {
  if (outcome_type == "binary") {
    y <- factor(as.character(y), levels = c("0", "1"))
    fastPLS::pls(X, y, ncomp = ncomp, classifier = "lda", fit = TRUE,
                 return_loadings = TRUE, rsvd_oversample = cfg$rsvd_oversample,
                 rsvd_power = cfg$rsvd_power, seed = seed)
  } else {
    fastPLS::pls(X, y, ncomp = ncomp, fit = TRUE,
                 return_loadings = TRUE, rsvd_oversample = cfg$rsvd_oversample,
                 rsvd_power = cfg$rsvd_power, seed = seed)
  }
}
