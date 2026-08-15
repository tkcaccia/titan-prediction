.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages(library(fastPLS))

predict_titan_model <- function(model_file, titan_features,
                                patient_id = NULL, cancer_type = NULL,
                                filename_column = "filename") {
  artifact <- readRDS(model_file)
  x <- as.data.frame(titan_features, check.names = FALSE)
  missing <- setdiff(artifact$feature_names, names(x))
  if (length(missing)) {
    stop("Missing TITAN feature columns: ", paste(head(missing, 10), collapse = ", "))
  }
  if (is.null(patient_id)) {
    if (!filename_column %in% names(x)) {
      stop("Supply patient_id or a filename column containing TCGA-style slide IDs.")
    }
    patient_id <- substr(x[[filename_column]], 1, 12)
  }
  if (length(patient_id) != nrow(x)) stop("patient_id must have one value per slide.")
  if (!is.null(artifact$cancer_type)) {
    if (is.null(cancer_type)) {
      warning("This is a cancer-specific model for ", artifact$cancer_type,
              "; confirm that every supplied slide belongs to that cancer.")
    } else {
      cancer_type <- as.character(cancer_type)
      if (length(cancer_type) == 1L) cancer_type <- rep(cancer_type, nrow(x))
      if (length(cancer_type) != nrow(x) ||
          any(is.na(cancer_type) | cancer_type != artifact$cancer_type)) {
        stop("All supplied slides must have cancer_type=", artifact$cancer_type,
             " for this model.")
      }
    }
  }
  X <- as.matrix(x[, artifact$feature_names, drop = FALSE])
  if (any(!is.finite(X))) stop("TITAN features must be finite numeric values.")
  ids <- unique(as.character(patient_id))
  group <- match(patient_id, ids)
  pooled <- rowsum(X, group = group, reorder = FALSE) /
    tabulate(group, nbins = length(ids))
  pred <- predict(artifact$model, pooled, raw_scores = artifact$outcome_type == "binary")
  if (artifact$outcome_type == "binary") {
    score <- drop(pred$LDA_scores[, 2, 1] - pred$LDA_scores[, 1, 1])
    data.frame(patient_id = ids, predicted_class = pred$Ypred[, 1],
               lda_score = score, check.names = FALSE)
  } else {
    values <- if (length(dim(pred$Ypred)) == 3L) {
      drop(pred$Ypred[, 1, 1])
    } else {
      drop(pred$Ypred)
    }
    data.frame(patient_id = ids, prediction = values,
               check.names = FALSE)
  }
}

# Example:
# slides <- data.table::fread("my_titan_slide_features.csv")
# predict_titan_model("models/driver_mutation__THCA__BRAF.rds", slides,
#                     cancer_type = "THCA")
