.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")

# Secondary analysis: compare response-by-response PLS1 with joint PLS2 only
# for coherent immune/inflammatory blocks. Binary molecular endpoints retain
# the primary PLS-score + LDA analysis in R/05_screen_binary.R.
cfg <- load_project_config()
cohort <- readRDS("data/processed/patient_cohort.rds")
targets <- readRDS("data/processed/continuous_targets.rds")
targets <- targets[family == "thorsson"]

blocks <- list(
  infiltration_signatures = c(
    "Leukocyte Fraction", "Stromal Fraction", "TIL Regional Fraction",
    "Wound Healing", "Macrophage Regulation",
    "Lymphocyte Infiltration Signature Score", "IFN-gamma Response",
    "TGF-beta Response"
  ),
  immune_repertoire = c(
    "BCR Shannon", "BCR Richness", "BCR Evenness",
    "TCR Shannon", "TCR Richness", "TCR Evenness"
  ),
  inferred_cell_fractions = c(
    "Th1 Cells", "Th2 Cells", "Th17 Cells", "B Cells Memory",
    "B Cells Naive", "Dendritic Cells Activated", "Dendritic Cells Resting",
    "Eosinophils", "Macrophages M0", "Macrophages M1", "Macrophages M2",
    "Mast Cells Activated", "Mast Cells Resting", "Monocytes", "Neutrophils",
    "NK Cells Activated", "NK Cells Resting", "Plasma Cells",
    "T Cells CD4 Memory Activated", "T Cells CD4 Memory Resting",
    "T Cells CD4 Naive", "T Cells CD8", "T Cells Follicular Helper",
    "T Cells gamma delta", "T Cells Regulatory Tregs"
  )
)
blocks <- lapply(blocks, intersect, y = unique(targets$endpoint))

ncomp_grid <- cfg$analysis$components
k_outer <- cfg$analysis$outer_folds
k_inner <- cfg$analysis$inner_folds
comparison_repeats <- 3L
min_n <- cfg$analysis$continuous_min_n
base_seed <- cfg$analysis$seed + 800000L

make_folds <- function(n, k, seed) {
  set.seed(seed)
  sample(rep(seq_len(k), length.out = n))
}

q2 <- function(y, pred) {
  den <- sum((y - mean(y))^2)
  if (!is.finite(den) || den <= 0) return(NA_real_)
  1 - sum((y - pred)^2) / den
}

fit_predict <- function(Xtrain, Ytrain, Xtest, ncomp, seed) {
  ym <- colMeans(Ytrain)
  ys <- apply(Ytrain, 2, sd)
  if (any(!is.finite(ys) | ys <= 0)) stop("non-variable training response")
  Yz <- sweep(sweep(Ytrain, 2, ym, "-"), 2, ys, "/")
  fit <- pls(
    Xtrain = Xtrain, Ytrain = Yz, Xtest = Xtest, ncomp = ncomp,
    scaling = "autoscaling", method = "simpls", svd.method = "irlba",
    seed = seed, fit = FALSE, return_variance = FALSE
  )
  pred <- fit$Ypred
  if (length(dim(pred)) == 3L) pred <- pred[, , 1L, drop = TRUE]
  pred <- as.matrix(pred)
  if (ncol(pred) != ncol(Ytrain)) pred <- matrix(pred, ncol = ncol(Ytrain))
  sweep(sweep(pred, 2, ys, "*"), 2, ym, "+")
}

select_ncomp <- function(X, Y, kfold, seed) {
  ym <- colMeans(Y)
  ys <- apply(Y, 2, sd)
  if (any(!is.finite(ys) | ys <= 0)) stop("non-variable inner-CV response")
  Yz <- sweep(sweep(Y, 2, ym, "-"), 2, ys, "/")
  fit <- pls.single.cv(
    Xdata = X, Ydata = Yz, ncomp = ncomp_grid, kfold = kfold,
    seed = seed, scaling = "autoscaling", method = "simpls",
    svd.method = "irlba", fit = FALSE, selection_metric = "q2"
  )
  as.integer(fit$best_ncomp)
}

run_once <- function(X, Y, tumor_type, block, repeat_id) {
  outer <- make_folds(
    nrow(Y), min(k_outer, floor(nrow(Y) / 8)),
    base_seed + repeat_id * 100000L
  )
  fold_values <- sort(unique(outer))
  keep <- vapply(seq_len(ncol(Y)), function(j) {
    all(vapply(fold_values, function(f) {
      is.finite(sd(Y[outer != f, j])) && sd(Y[outer != f, j]) > 0
    }, logical(1)))
  }, logical(1))
  Y <- Y[, keep, drop = FALSE]
  if (ncol(Y) < 2L) return(NULL)

  pred1 <- matrix(NA_real_, nrow(Y), ncol(Y), dimnames = dimnames(Y))
  pred2 <- matrix(NA_real_, nrow(Y), ncol(Y), dimnames = dimnames(Y))
  nc1 <- matrix(NA_integer_, length(fold_values), ncol(Y))
  nc2 <- integer(length(fold_values))

  for (f in fold_values) {
    fi <- match(f, fold_values)
    te <- which(outer == f)
    tr <- which(outer != f)
    inner_k <- min(k_inner, floor(length(tr) / 8))

    nc2[fi] <- select_ncomp(
      X[tr, , drop = FALSE], Y[tr, , drop = FALSE], inner_k,
      base_seed + repeat_id * 100000L + 2000L + f
    )
    pred2[te, ] <- fit_predict(
      X[tr, , drop = FALSE], Y[tr, , drop = FALSE],
      X[te, , drop = FALSE], nc2[fi],
      base_seed + repeat_id * 100000L + 3000L + f
    )

    for (j in seq_len(ncol(Y))) {
      yy <- Y[, j, drop = FALSE]
      nc1[fi, j] <- select_ncomp(
        X[tr, , drop = FALSE], yy[tr, , drop = FALSE], inner_k,
        base_seed + repeat_id * 100000L + 4000L + 100L * j + f
      )
      pred1[te, j] <- fit_predict(
        X[tr, , drop = FALSE], yy[tr, , drop = FALSE],
        X[te, , drop = FALSE], nc1[fi, j],
        base_seed + repeat_id * 100000L + 5000L + 100L * j + f
      )[, 1]
    }
  }

  rows <- rbindlist(lapply(seq_len(ncol(Y)), function(j) {
    data.table(
      tumor_type = tumor_type, block = block, endpoint = colnames(Y)[j],
      repeat_id = repeat_id, n = nrow(Y), metric = "Q2",
      pls1 = q2(Y[, j], pred1[, j]), pls2 = q2(Y[, j], pred2[, j]),
      median_ncomp_pls1 = median(nc1[, j]),
      median_ncomp_pls2 = median(nc2)
    )
  }))
  rows[, delta_pls2_minus_pls1 := pls2 - pls1]
  list(
    rows = rows,
    predictions = list(
      patient = rownames(Y), observed = Y, pls1 = pred1, pls2 = pred2,
      outer_fold = outer, ncomp_pls1 = nc1, ncomp_pls2 = nc2
    )
  )
}

build_matrix <- function(cancer, endpoints) {
  patients <- cohort$meta[tumor_type == cancer, patient]
  d <- targets[tumor_type == cancer & endpoint %in% endpoints]
  if (!nrow(d)) return(NULL)
  wide <- dcast(d, patient ~ endpoint, value.var = "value")
  endpoint_cols <- intersect(endpoints, names(wide))
  wide <- wide[patient %in% patients]
  complete <- complete.cases(wide[, ..endpoint_cols])
  wide <- wide[complete]
  if (nrow(wide) < min_n || length(endpoint_cols) < 2L) return(NULL)
  idx <- match(wide$patient, rownames(cohort$X))
  list(
    X = cohort$X[idx, , drop = FALSE],
    Y = `rownames<-`(as.matrix(wide[, ..endpoint_cols]), wide$patient)
  )
}

job_grid <- CJ(
  tumor_type = sort(unique(na.omit(cohort$meta$tumor_type))),
  block = names(blocks)
)
checkpoint_dir <- "data/processed/checkpoints/pls1_vs_pls2"
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)

run_job <- function(i) {
  job <- job_grid[i]
  path <- paste0(file.path(
    checkpoint_dir, safe_name(job$tumor_type, job$block)
  ), ".rds")
  if (file.exists(path)) return(NULL)
  z <- build_matrix(job$tumor_type, blocks[[job$block]])
  if (is.null(z)) {
    saveRDS(NULL, path)
    return(NULL)
  }
  ans <- lapply(seq_len(comparison_repeats), function(r) {
    run_once(z$X, z$Y, job$tumor_type, job$block, r)
  })
  ans <- ans[!vapply(ans, is.null, logical(1))]
  saveRDS(ans, path, compress = "xz")
  NULL
}

workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
future::plan(future::multicore, workers = workers)
invisible(future_lapply(
  seq_len(nrow(job_grid)), run_job, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table"), future.globals = TRUE,
  future.chunk.size = 1
))

objects <- lapply(list.files(checkpoint_dir, full.names = TRUE), readRDS)
objects <- unlist(objects, recursive = FALSE)
objects <- objects[!vapply(objects, is.null, logical(1))]
by_repeat <- rbindlist(lapply(objects, `[[`, "rows"), fill = TRUE)
setorder(by_repeat, tumor_type, block, endpoint, repeat_id)
fwrite(by_repeat, "results/tables/pls1_vs_pls2_inflammation_by_repeat.csv")

summary <- by_repeat[, .(
  n = first(n), metric = first(metric),
  pls1 = mean(pls1), pls2 = mean(pls2),
  delta_pls2_minus_pls1 = mean(delta_pls2_minus_pls1),
  sd_delta = sd(delta_pls2_minus_pls1),
  median_ncomp_pls1 = mean(median_ncomp_pls1),
  median_ncomp_pls2 = mean(median_ncomp_pls2),
  n_repeats = uniqueN(repeat_id)
), by = .(tumor_type, block, endpoint)]
fwrite(summary, "results/tables/pls1_vs_pls2_inflammation.csv")

cancer <- summary[, .(
  n_endpoints = .N,
  median_delta = median(delta_pls2_minus_pls1),
  mean_delta = mean(delta_pls2_minus_pls1)
), by = .(tumor_type, block)]
fwrite(cancer, "results/tables/pls1_vs_pls2_inflammation_by_cancer.csv")

set.seed(base_seed + 900000L)
overall <- cancer[, {
  boot <- replicate(10000L, mean(sample(mean_delta, .N, replace = TRUE)))
  .(
    n_cancers = .N, median_cancer_delta = median(mean_delta),
    mean_cancer_delta = mean(mean_delta),
    ci_low = unname(quantile(boot, 0.025)),
    ci_high = unname(quantile(boot, 0.975)),
    wilcoxon_p = wilcox.test(mean_delta, mu = 0, exact = FALSE)$p.value
  )
}, by = block]
fwrite(overall, "results/tables/pls1_vs_pls2_inflammation_summary.csv")
saveRDS(lapply(objects, `[[`, "predictions"),
        "results/predictions/pls1_vs_pls2_inflammation_oof.rds", compress = "xz")
print(overall)
