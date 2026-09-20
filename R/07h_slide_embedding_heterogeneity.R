suppressPackageStartupMessages(library(data.table))
source("R/utils.R")
cfg <- load_project_config()

specs <- list(
  TITAN = list(path = cfg$paths$titan_features, pattern = "^titan_[0-9]{3}$"),
  GigaSSL = list(path = cfg$paths$gigassl_features, pattern = "^gigassl_[0-9]{3}$"),
  ProvGigaPath = list(path = cfg$paths$provgigapath_features,
                      pattern = "^provgigapath_[0-9]{3}$")
)

cosine_distance <- function(a, b) {
  den <- sqrt(sum(a * a)) * sqrt(sum(b * b))
  if (!is.finite(den) || den <= 0) return(NA_real_)
  1 - sum(a * b) / den
}

audit_model <- function(model, spec) {
  d <- fread(spec$path)
  features <- grep(spec$pattern, names(d), value = TRUE)
  d[, `:=`(patient = substr(filename, 1, 12),
            sample_type = substr(filename, 14, 15))]
  d <- d[sample_type == "01" & grepl("-DX", filename)]
  setorder(d, patient, filename)
  X <- as.matrix(d[, ..features])
  storage.mode(X) <- "double"
  groups <- split(seq_len(nrow(d)), d$patient)
  rows <- lapply(names(groups), function(patient) {
    idx <- groups[[patient]]
    z <- X[idx, , drop = FALSE]
    n <- nrow(z)
    if (n == 1L) return(data.table(
      foundation_model = model, patient = patient, n_slides = 1L,
      mean_pairwise_cosine_distance = 0,
      maximum_pairwise_cosine_distance = 0,
      mean_slide_to_centroid_cosine_distance = 0,
      maximum_slide_to_centroid_cosine_distance = 0,
      mean_vs_median_centroid_cosine_distance = 0,
      maximum_leave_one_slide_out_centroid_cosine_distance = 0
    ))
    centre <- colMeans(z)
    median_centre <- apply(z, 2L, median)
    to_centre <- apply(z, 1L, cosine_distance, b = centre)
    pairwise <- if (n > 1L) {
      cmb <- combn(n, 2L)
      apply(cmb, 2L, function(k) cosine_distance(z[k[1], ], z[k[2], ]))
    } else 0
    loo <- if (n > 1L) vapply(seq_len(n), function(i) {
      cosine_distance(centre, colMeans(z[-i, , drop = FALSE]))
    }, numeric(1)) else 0
    data.table(
      foundation_model = model, patient = patient, n_slides = n,
      mean_pairwise_cosine_distance = mean(pairwise, na.rm = TRUE),
      maximum_pairwise_cosine_distance = max(pairwise, na.rm = TRUE),
      mean_slide_to_centroid_cosine_distance = mean(to_centre, na.rm = TRUE),
      maximum_slide_to_centroid_cosine_distance = max(to_centre, na.rm = TRUE),
      mean_vs_median_centroid_cosine_distance = cosine_distance(centre, median_centre),
      maximum_leave_one_slide_out_centroid_cosine_distance = max(loo, na.rm = TRUE)
    )
  })
  rbindlist(rows)
}

detail <- rbindlist(Map(audit_model, names(specs), specs), fill = TRUE)
meta <- fread("results/tables/patient_cohort_summary.csv")[, .(patient, tumor_type)]
detail <- merge(detail, meta, by = "patient", all.x = TRUE)
detail[, slide_count_band := fifelse(n_slides == 1L, "1",
  fifelse(n_slides == 2L, "2", fifelse(n_slides <= 5L, "3-5", ">5")))]
summary <- detail[, .(
  patients = .N,
  multi_slide_patients = sum(n_slides > 1L),
  median_pairwise_cosine_distance = median(mean_pairwise_cosine_distance[n_slides > 1L], na.rm = TRUE),
  q95_pairwise_cosine_distance = quantile(mean_pairwise_cosine_distance[n_slides > 1L], .95, na.rm = TRUE),
  median_mean_vs_median_centroid_distance = median(mean_vs_median_centroid_cosine_distance[n_slides > 1L], na.rm = TRUE),
  q95_mean_vs_median_centroid_distance = quantile(mean_vs_median_centroid_cosine_distance[n_slides > 1L], .95, na.rm = TRUE),
  median_maximum_loo_centroid_distance = median(maximum_leave_one_slide_out_centroid_cosine_distance[n_slides > 1L], na.rm = TRUE),
  q95_maximum_loo_centroid_distance = quantile(maximum_leave_one_slide_out_centroid_cosine_distance[n_slides > 1L], .95, na.rm = TRUE)
), by = foundation_model]
fwrite(detail, "results/tables/slide_embedding_heterogeneity_patient_level.csv")
fwrite(summary, "results/tables/slide_embedding_heterogeneity_summary.csv")
fwrite(detail[patient == "TCGA-DX-AB2L"],
       "results/tables/slide_embedding_heterogeneity_maximum_slide_patient.csv")
print(summary)
