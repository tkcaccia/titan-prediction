.libPaths(c(file.path(getwd(), ".Rlib"), .libPaths()))
library(data.table)
library(ggplot2)
library(PathoFMPred)
library(patchwork)

patient_ids <- c("TCGA-AA-A01F", "TCGA-A6-A56B")
foundation_models <- c("TITAN", "GigaSSL", "ProvGigaPath")

model_labels <- c(
  TITAN = "TITAN",
  GigaSSL = "Giga-SSL",
  ProvGigaPath = "Prov-GigaPath"
)

model_colours <- c(
  TITAN = "#2C7FB8",
  GigaSSL = "#E07A3F",
  ProvGigaPath = "#2A9D8F"
)

predict_one_representation <- function(foundation_model) {
  cohort <- readRDS(file.path(
    "data", "processed", paste0("patient_cohort_", foundation_model, ".rds")
  ))
  idx <- match(patient_ids, cohort$meta$patient)
  if (anyNA(idx)) {
    stop("The two COAD example patients are not available for ", foundation_model)
  }

  features <- as.data.frame(cohort$X[idx, , drop = FALSE], check.names = FALSE)
  predictions <- predict_pathofm(
    cancer = "COAD",
    features = features,
    foundation_model = foundation_model,
    patient_id = patient_ids,
    outcome_type = "continuous",
    warn_ood = FALSE
  )
  predictions$source_slide_count <- cohort$meta$n_slides[idx][
    match(predictions$patient_id, patient_ids)
  ]
  as.data.table(predictions)
}

predictions <- rbindlist(
  lapply(foundation_models, predict_one_representation),
  use.names = TRUE,
  fill = TRUE
)

stopifnot(all(
  predictions$predictable_for_selected_cancer_and_representation %in% TRUE
))
setorder(predictions, patient_id, foundation_model, family, endpoint)

output_columns <- c(
  "patient_id", "cancer", "foundation_model", "source_slide_count",
  "model_id", "family", "endpoint", "outcome_type", "prediction",
  "output_units", "reference_percentile", "rank_interpretation",
  "training_n", "primary_screen_q2", "primary_screen_rmse",
  "primary_screen_spearman", "model_evidence_tier", "default_inference",
  "predictable_for_selected_cancer_and_representation", "predictability_rule",
  "representation_effect_threshold_crossing",
  "matched_representation_effect_threshold_crossing", "site_robustness_status",
  "site_robustness_warning"
)
fwrite(
  predictions[, intersect(output_columns, names(predictions)), with = FALSE],
  file.path("results", "tables", "coad_pathofmpred_multifoundation_predictions.csv")
)

radar_panels <- list()
radar_endpoint_labels <- c(
  HALLMARK_MYOGENESIS = "Myogenesis",
  HALLMARK_INTERFERON_GAMMA_RESPONSE = "IFN-gamma response",
  HALLMARK_INTERFERON_ALPHA_RESPONSE = "IFN-alpha response",
  HALLMARK_IL6_JAK_STAT3_SIGNALING = "IL6/JAK/STAT3 signalling",
  HALLMARK_ALLOGRAFT_REJECTION = "Allograft rejection",
  `Silent Mutation Rate` = "Silent rate",
  `Nonsilent Mutation Rate` = "Non-silent rate",
  `Aneuploidy Score` = "Aneuploidy (immune atlas)",
  `Aneuploidy score` = "Aneuploidy (Taylor)"
)
for (patient_index in seq_along(patient_ids)) {
  for (model_name in foundation_models) {
    d <- predictions[
      patient_id == patient_ids[patient_index] &
        foundation_model == model_name
    ]
    d_plot <- copy(d)
    replacement_index <- match(d_plot$endpoint, names(radar_endpoint_labels))
    replace_rows <- which(!is.na(replacement_index))
    d_plot$endpoint[replace_rows] <- unname(
      radar_endpoint_labels[replacement_index[replace_rows]]
    )
    panel_title <- paste0(
      if (patient_index == 1L) "Patient A | " else "Patient B | ",
      model_labels[[model_name]], " (", nrow(d), " endpoints)"
    )
    radar_panels[[length(radar_panels) + 1L]] <-
      plot_pathofm_radar(as.data.frame(d_plot), max_endpoints = Inf) +
      labs(title = panel_title, subtitle = NULL) +
      theme(
        plot.title = element_text(
          face = "bold", size = 10.8, colour = "#172B4D", hjust = 0.5
        ),
        plot.margin = margin(10, 18, 10, 18)
      )
  }
}

radar_grid <- list(
  radar_panels[[1L]], plot_spacer(), radar_panels[[4L]],
  radar_panels[[2L]], plot_spacer(), radar_panels[[5L]],
  radar_panels[[3L]], plot_spacer(), radar_panels[[6L]]
)
p <- wrap_plots(radar_grid, ncol = 3, widths = c(1, 0.13, 1)) +
  plot_annotation(
    title = "PathoFMPred profiles for two COAD patients across three slide representations",
    subtitle = paste0(
      "Columns compare patients; rows compare representations. Each panel shows only endpoints predictable for that representation.\n",
      "Radius is the internal TCGA reference percentile; corner values are original predictions."
    ),
    caption = paste0(
      "Panels can contain different endpoints. Compare shared axes directly. Patient A is TCGA-AA-A01F; Patient B is TCGA-A6-A56B.\n",
      "Reference percentiles are not probabilities or clinical reference intervals."
    ),
    theme = theme(
      plot.title = element_text(face = "bold", size = 17, colour = "#172B4D", hjust = 0.5),
      plot.subtitle = element_text(size = 11, colour = "#526579", hjust = 0.5),
      plot.caption = element_text(size = 9.5, colour = "#526579", hjust = 0)
    )
  )

figure_paths <- c(
  file.path("results", "figures", "Figure3_COAD_PathoFMPred_multifoundation_examples.png"),
  file.path("figures", "Figure3_COAD_PathoFMPred_multifoundation_examples.png")
)
for (path in figure_paths) {
  ggsave(path, p, width = 10.8, height = 13.0, dpi = 320, bg = "white")
}

pdf_path <- file.path(
  "figures", "Figure3_COAD_PathoFMPred_multifoundation_examples.pdf"
)
ggsave(pdf_path, p, width = 10.8, height = 13.0, device = cairo_pdf, bg = "white")

message(
  "Saved ", nrow(predictions), " representation-specific predictable continuous outputs for ",
  uniqueN(predictions$patient_id), " patients and ",
  uniqueN(predictions$foundation_model), " representations."
)

# Complete binary outputs for the same two illustrative patients -------------
#
# Binary PathoFMPred outputs are uncalibrated LDA class calls and scores. The
# internal TCGA reference rank is useful for displaying where a score lies
# within the training reference distribution, but it is not a probability.

predict_binary_one_representation <- function(foundation_model) {
  cohort <- readRDS(file.path(
    "data", "processed", paste0("patient_cohort_", foundation_model, ".rds")
  ))
  idx <- match(patient_ids, cohort$meta$patient)
  if (anyNA(idx)) {
    stop("The two COAD example patients are not available for ", foundation_model)
  }

  features <- as.data.frame(cohort$X[idx, , drop = FALSE], check.names = FALSE)
  mutation_predictions <- predict_pathofm(
    cancer = "COAD",
    features = features,
    foundation_model = foundation_model,
    patient_id = patient_ids,
    outcome_type = "binary",
    warn_ood = FALSE
  )
  mutation_predictions$source_slide_count <- cohort$meta$n_slides[idx][
    match(mutation_predictions$patient_id, patient_ids)
  ]
  as.data.table(mutation_predictions)
}

binary_predictions <- rbindlist(
  lapply(foundation_models, predict_binary_one_representation),
  use.names = TRUE,
  fill = TRUE
)

stopifnot(all(
  binary_predictions$predictable_for_selected_cancer_and_representation %in% TRUE
))
setorder(binary_predictions, patient_id, family, endpoint, foundation_model)

if (!nrow(binary_predictions)) stop("No predictable COAD binary model was returned.")

binary_output_columns <- c(
  "patient_id", "cancer", "foundation_model", "source_slide_count",
  "model_id", "family", "endpoint", "outcome_type", "predicted_class",
  "lda_score", "reference_percentile", "reference_rank",
  "rank_interpretation", "rank_is_probability", "calibration_status",
  "training_n", "training_positive", "training_negative",
  "repeated_auc", "repeated_pr_auc", "model_evidence_tier",
  "default_inference", "predictable_for_selected_cancer_and_representation",
  "predictability_rule", "representation_effect_threshold_crossing",
  "matched_representation_effect_threshold_crossing",
  "site_robustness_status", "site_robustness_warning"
)
fwrite(
  binary_predictions[, intersect(binary_output_columns, names(binary_predictions)),
                     with = FALSE],
  file.path(
    "results", "tables",
    "coad_pathofmpred_multifoundation_binary_predictions.csv"
  )
)

# Retain a mutation-only companion for backward compatibility, while the
# manuscript figure and patient reports use the complete binary output.
mutation_predictions <- binary_predictions[family == "driver_mutation"]
fwrite(
  mutation_predictions[, intersect(binary_output_columns, names(mutation_predictions)),
                       with = FALSE],
  file.path(
    "results", "tables",
    "coad_pathofmpred_multifoundation_mutation_predictions.csv"
  )
)

message(
  "Saved ", nrow(binary_predictions), " complete binary outputs for ",
  uniqueN(binary_predictions$patient_id), " patients and ",
  uniqueN(binary_predictions$foundation_model), " representations; ",
  nrow(mutation_predictions), " rows are mutation-only compatibility records."
)
