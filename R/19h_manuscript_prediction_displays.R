#!/usr/bin/env Rscript

# Create the reader-facing prediction displays used in the main manuscript.
# This script does not refit a model. It visualizes saved patient-level
# out-of-fold predictions and saved PathoFMPred example calls.

.libPaths(c(file.path(getwd(), ".Rlib"), .libPaths()))
suppressPackageStartupMessages(library(ggplot2))

root <- normalizePath(".", mustWork = TRUE)
prediction_file <- file.path(
  root, "results", "predictions", "foundation_model_matched_oof.rds"
)
binary_file <- file.path(
  root, "results", "tables",
  "coad_pathofmpred_multifoundation_binary_predictions.csv"
)
figure_dir <- file.path(root, "figures")
result_figure_dir <- file.path(root, "results", "figures")
dir.create(figure_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(result_figure_dir, showWarnings = FALSE, recursive = TRUE)

model_order <- c("TITAN", "GigaSSL", "ProvGigaPath")
model_labels <- c(
  TITAN = "TITAN",
  GigaSSL = "Giga-SSL",
  ProvGigaPath = "Prov-GigaPath"
)
model_colours <- c(
  TITAN = "#2F6DA1",
  GigaSSL = "#E68613",
  ProvGigaPath = "#2A9D8F"
)

q2_value <- function(observed, predicted) {
  1 - sum((observed - predicted)^2) /
    sum((observed - mean(observed))^2)
}

oof <- readRDS(prediction_file)
selected <- subset(
  oof,
  outcome_type == "continuous" &
    family == "thorsson" &
    tumor_type == "TGCT" &
    endpoint == "TGF-beta Response"
)
stopifnot(nrow(selected) > 0L)
stopifnot(all(model_order %in% unique(selected$foundation_model)))

observed_prediction_path <- file.path(
  figure_dir, "Figure4_observed_vs_predicted_TGCT_TGFbeta.png"
)
png(
  observed_prediction_path,
  width = 3300,
  height = 1350,
  res = 300,
  bg = "white"
)
par(
  mfrow = c(1, 3),
  oma = c(3.2, 3.2, 3.6, 0.5),
  mar = c(4.3, 4.4, 3.8, 1.0),
  family = "sans"
)
limits <- range(c(selected$observed, selected$predicted), finite = TRUE)
padding <- diff(limits) * 0.04
limits <- limits + c(-padding, padding)

for (model in model_order) {
  values <- selected[selected$foundation_model == model, ]
  metric_q2 <- q2_value(values$observed, values$predicted)
  metric_rho <- suppressWarnings(cor(
    values$observed, values$predicted, method = "spearman"
  ))
  plot(
    values$observed,
    values$predicted,
    xlim = limits,
    ylim = limits,
    asp = 1,
    pch = 21,
    cex = 0.86,
    bg = grDevices::adjustcolor(model_colours[[model]], alpha.f = 0.50),
    col = grDevices::adjustcolor(model_colours[[model]], alpha.f = 0.82),
    xlab = "Observed reference value",
    ylab = "Out-of-fold predicted value",
    main = model_labels[[model]],
    cex.main = 1.35,
    cex.lab = 1.05,
    cex.axis = 0.90,
    las = 1
  )
  grid(col = "#E5E9EF", lty = 1)
  abline(a = 0, b = 1, col = "#59636E", lwd = 2, lty = 2)
  abline(lm(predicted ~ observed, data = values),
         col = model_colours[[model]], lwd = 2.5)
  points(
    values$observed,
    values$predicted,
    pch = 21,
    cex = 0.86,
    bg = grDevices::adjustcolor(model_colours[[model]], alpha.f = 0.50),
    col = grDevices::adjustcolor(model_colours[[model]], alpha.f = 0.82)
  )
  legend(
    "topleft",
    legend = sprintf(
      "n = %d\nQ2 = %.3f\nSpearman rho = %.3f",
      nrow(values), metric_q2, metric_rho
    ),
    bty = "n",
    text.col = "#243447",
    cex = 0.94
  )
}
mtext(
  "TGCT TGF-beta response: observed and patient-level out-of-fold predictions",
  outer = TRUE,
  side = 3,
  line = 1.3,
  cex = 1.45,
  font = 2,
  col = "#17365D"
)
mtext(
  "Each point is one patient. Dashed line indicates perfect agreement; coloured line is the fitted linear trend.",
  outer = TRUE,
  side = 1,
  line = 1.2,
  cex = 0.88,
  col = "#526579"
)
dev.off()
file.copy(
  observed_prediction_path,
  file.path(result_figure_dir, basename(observed_prediction_path)),
  overwrite = TRUE
)

binary <- read.csv(binary_file, stringsAsFactors = FALSE, check.names = FALSE)
binary <- subset(
  binary,
  predictable_for_selected_cancer_and_representation %in% c(TRUE, "TRUE") &
    foundation_model %in% model_order
)
patients <- c("TCGA-AA-A01F", "TCGA-A6-A56B")
stopifnot(all(patients %in% binary$patient_id))

feature_order <- data.frame(
  family = c(
    "aneuploidy",
    rep("driver_mutation", 3),
    "microsatellite_instability",
    "microsatellite_instability_sensitivity",
    rep("oncogenic_pathway", 2)
  ),
  endpoint = c(
    "Genome doubling", "APC", "KRAS", "TP53",
    "MSI-H (MANTIS >0.4)", "MSI-H strict (MANTIS >0.6)",
    "MYC", "TP53"
  ),
  feature_label = c(
    "Genome doubling",
    "Mutation | APC", "Mutation | KRAS", "Mutation | TP53",
    "MSI-H | MANTIS >0.4", "MSI-H strict | MANTIS >0.6",
    "Pathway | MYC", "Pathway | TP53"
  ),
  stringsAsFactors = FALSE
)
feature_order$feature_key <- paste(feature_order$family, feature_order$endpoint, sep = "||")
binary$feature_key <- paste(binary$family, binary$endpoint, sep = "||")
binary <- merge(binary, feature_order, by = c("family", "endpoint", "feature_key"), all.x = TRUE)
stopifnot(!anyNA(binary$feature_label))

complete_grid <- expand.grid(
  patient_id = patients,
  foundation_model = model_order,
  feature_key = feature_order$feature_key,
  stringsAsFactors = FALSE
)
complete_grid <- merge(
  complete_grid,
  feature_order[, c("feature_key", "family", "endpoint", "feature_label")],
  by = "feature_key",
  all.x = TRUE,
  sort = FALSE
)
binary_display <- merge(
  complete_grid,
  binary,
  by = c("patient_id", "foundation_model", "feature_key", "family", "endpoint", "feature_label"),
  all.x = TRUE,
  sort = FALSE
)

binary_display$patient_label <- factor(
  binary_display$patient_id,
  levels = patients,
  labels = paste0(c("Patient A | ", "Patient B | "), patients)
)
binary_display$representation_label <- factor(
  binary_display$foundation_model,
  levels = model_order,
  labels = unname(model_labels[model_order])
)
binary_display$feature_label <- factor(
  binary_display$feature_label,
  levels = rev(feature_order$feature_label)
)

positive_call <- function(family) {
  ifelse(
    family == "driver_mutation", "MUTATION",
    ifelse(
      family %in% c("microsatellite_instability", "microsatellite_instability_sensitivity"),
      "MSI-H", ifelse(family == "aneuploidy", "PRESENT", "ALTERED")
    )
  )
}
negative_call <- function(family) {
  ifelse(
    family == "driver_mutation", "WILD TYPE",
    ifelse(
      family %in% c("microsatellite_instability", "microsatellite_instability_sensitivity"),
      "NOT MSI-H", ifelse(family == "aneuploidy", "ABSENT", "NOT ALTERED")
    )
  )
}

binary_display$status <- ifelse(
  is.na(binary_display$predicted_class),
  "Not returned",
  ifelse(as.integer(binary_display$predicted_class) == 1L, "Positive call", "Negative call")
)
binary_display$call_text <- ifelse(
  is.na(binary_display$predicted_class),
  "NOT RETURNED",
  ifelse(
    as.integer(binary_display$predicted_class) == 1L,
    positive_call(binary_display$family),
    negative_call(binary_display$family)
  )
)
binary_display$cell_label <- ifelse(
  is.na(binary_display$predicted_class),
  binary_display$call_text,
  sprintf(
    "%s\nscore %.2f | rank %.1f",
    binary_display$call_text,
    binary_display$lda_score,
    binary_display$reference_rank
  )
)

binary_path <- file.path(
  figure_dir, "Figure6_COAD_PathoFMPred_full_binary_output.png"
)
p_binary <- ggplot(
  binary_display,
  aes(x = representation_label, y = feature_label)
) +
  geom_tile(aes(fill = status), colour = "white", linewidth = 0.75) +
  geom_text(
    aes(label = cell_label),
    colour = "#172B4D",
    size = 2.55,
    lineheight = 0.96,
    fontface = "bold"
  ) +
  facet_wrap(~patient_label, ncol = 1, scales = "fixed") +
  scale_fill_manual(
    values = c(
      "Positive call" = "#F6C3BB",
      "Negative call" = "#DCEAF5",
      "Not returned" = "#EEEEEE"
    ),
    breaks = c("Positive call", "Negative call", "Not returned")
  ) +
  labs(
    title = "Complete PathoFMPred binary output\nfor two COAD patients",
    subtitle = paste0(
      "All predictable binary features across TITAN, Giga-SSL and Prov-GigaPath.\n",
      "Cells show the class call, original LDA score and internal TCGA score rank."
    ),
    x = NULL,
    y = NULL,
    fill = NULL,
    caption = paste0(
      "Reference rank is not probability. LDA scores are uncalibrated and model-specific.\n",
      "NOT RETURNED means that the representation had no eligible threshold-crossing fitted object for the feature.\n",
      "Reference labels are unavailable for these two illustrative patients."
    )
  ) +
  theme_minimal(base_size = 8.4, base_family = "Arial") +
  theme(
    panel.grid = element_blank(),
    axis.text.x = element_text(face = "bold", size = 8.7, colour = "#172B4D"),
    axis.text.y = element_text(face = "bold", size = 7.7, colour = "#172B4D"),
    strip.text = element_text(face = "bold", size = 9.4, colour = "#172B4D"),
    strip.background = element_rect(fill = "#EAF1F7", colour = NA),
    plot.title = element_text(face = "bold", size = 12.2, colour = "#172B4D"),
    plot.subtitle = element_text(size = 8.2, colour = "#526579"),
    plot.caption = element_text(size = 6.8, colour = "#526579", hjust = 0),
    legend.position = "bottom",
    legend.text = element_text(size = 7.5),
    panel.spacing.y = grid::unit(0.34, "cm"),
    plot.margin = margin(8, 8, 8, 8)
  )

ggsave(
  binary_path,
  p_binary,
  width = 6.35,
  height = 8.15,
  dpi = 400,
  bg = "white"
)
file.copy(
  binary_path,
  file.path(result_figure_dir, basename(binary_path)),
  overwrite = TRUE
)
ggsave(
  file.path(figure_dir, "Figure6_COAD_PathoFMPred_full_binary_output.pdf"),
  p_binary,
  width = 6.35,
  height = 8.15,
  device = cairo_pdf,
  bg = "white"
)

message("Created observed-versus-predicted and complete binary-output figures.")
