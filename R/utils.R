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

balanced_accuracy <- function(truth, estimate) {
  truth <- factor(truth)
  estimate <- factor(estimate, levels = levels(truth))
  tab <- table(truth, estimate)
  mean(diag(tab) / rowSums(tab))
}

rank_auc <- function(truth, score, positive = "1") {
  y <- as.character(truth) == positive
  n1 <- sum(y); n0 <- sum(!y)
  if (!n1 || !n0) return(NA_real_)
  (sum(rank(score, ties.method = "average")[y]) - n1 * (n1 + 1) / 2) /
    (n1 * n0)
}

q_squared <- function(truth, estimate) {
  1 - sum((truth - estimate)^2) / sum((truth - mean(truth))^2)
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
      kfold = inner_k, seed = seed + fold, classifier = "lda",
      lda_ridge = cfg$lda_ridge, selection_metric = "balanced_accuracy",
      fit = FALSE
    )
    selected[fold] <- inner$best_ncomp
    fit <- fastPLS::pls(
      X[train, , drop = FALSE], y[train], ncomp = selected[fold],
      classifier = "lda", lda_ridge = cfg$lda_ridge, fit = TRUE,
      return_loadings = TRUE, seed = seed + 100L + fold
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
      kfold = cfg$inner_folds, seed = seed + fold, fit = FALSE
    )
    selected[fold] <- inner$best_ncomp
    fit <- fastPLS::pls(
      X[train, , drop = FALSE], y[train], ncomp = selected[fold],
      fit = TRUE, return_loadings = TRUE, seed = seed + 100L + fold
    )
    pred[test] <- as.numeric(predict(fit, X[test, , drop = FALSE])$Ypred[[1]])
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
    fastPLS::pls(X, y, ncomp = ncomp, classifier = "lda",
                 lda_ridge = cfg$lda_ridge, fit = TRUE,
                 return_loadings = TRUE, seed = seed)
  } else {
    fastPLS::pls(X, y, ncomp = ncomp, fit = TRUE,
                 return_loadings = TRUE, seed = seed)
  }
}

