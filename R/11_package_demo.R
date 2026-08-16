suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(patchwork)
  library(TITANPred)
})

dir.create("results/reports", recursive = TRUE, showWarnings = FALSE)
dir.create("results/predictions", recursive = TRUE, showWarnings = FALSE)
dir.create("results/tables", recursive = TRUE, showWarnings = FALSE)
dir.create("figures", recursive = TRUE, showWarnings = FALSE)

cohort <- readRDS("data/processed/patient_cohort.rds")
coad_rows <- which(!is.na(cohort$meta$tumor_type) & cohort$meta$tumor_type == "COAD")
coad_predictions <- suppressWarnings(predict_titan(
  cancer = "COAD",
  features = cohort$X[coad_rows, , drop = FALSE],
  patient_id = cohort$meta$patient[coad_rows]
))
saveRDS(coad_predictions, "results/predictions/coad_package_predictions.rds")

# Select the pair with the largest Euclidean separation over the complete
# continuous reference-percentile profile. This is a deployment illustration,
# not an additional validation analysis.
continuous <- as.data.table(coad_predictions)[outcome_type == "continuous"]
profile <- dcast(continuous, patient_id ~ endpoint, value.var = "reference_percentile")
profile_ids <- profile$patient_id
profile_matrix <- as.matrix(profile[, -"patient_id"])
distance_matrix <- as.matrix(dist(profile_matrix))
diag(distance_matrix) <- -Inf
pair_index <- which(distance_matrix == max(distance_matrix), arr.ind = TRUE)[1L, ]
selected_ids <- profile_ids[pair_index]

# Stable labels make the public figure readable while retaining IDs in the
# machine-readable provenance table.
example_map <- data.table(
  patient_id = selected_ids,
  example = c("COAD example A", "COAD example B")
)
example_map <- merge(
  example_map,
  as.data.table(cohort$meta)[, .(patient_id = patient, n_input_slides = n_slides)],
  by = "patient_id", all.x = TRUE, sort = FALSE
)
example_map[, profile_distance := max(distance_matrix)]
fwrite(example_map, "results/tables/coad_package_examples.csv")

selected <- merge(as.data.table(coad_predictions), example_map,
                  by = "patient_id", all = FALSE, sort = FALSE)
fwrite(selected, "results/tables/coad_package_example_predictions.csv")

for (i in seq_len(nrow(example_map))) {
  row_index <- match(example_map$patient_id[i], cohort$meta$patient)
  titan_sample_report(
    cancer = "COAD",
    features = cohort$X[row_index, , drop = FALSE],
    patient_id = example_map$patient_id[i],
    output_file = file.path("results", "reports", gsub(" ", "_", example_map$example[i])),
    format = "both",
    quiet = TRUE
  )
}

navy <- "#17324D"
teal <- "#00A7A5"
coral <- "#F05D5E"
muted <- "#64748B"
sample_palette <- c("COAD example A" = teal, "COAD example B" = coral)

radar <- selected[outcome_type == "continuous" &
                    !(family == "thorsson" & endpoint == "Aneuploidy Score")]
radar[, endpoint_label := fcase(
  endpoint == "Lymphocyte Infiltration Signature Score", "Lymphocytes",
  endpoint == "TIL Regional Fraction", "TIL",
  endpoint == "Nonsilent Mutation Rate", "Nonsilent rate",
  endpoint == "Silent Mutation Rate", "Silent rate",
  endpoint == "SNV Neoantigens", "SNV neoantigens",
  endpoint == "Deleted arm count", "Deleted arms",
  endpoint == "Aneuploidy score", "Aneuploidy",
  endpoint == "MANTIS score", "MANTIS",
  endpoint == "MSIsensor score", "MSIsensor",
  default = endpoint
)]
radar_order <- c(
  "Lymphocytes", "MANTIS", "TIL", "MSIsensor", "Nonsilent rate",
  "Aneuploidy", "SNV neoantigens", "Deleted arms", "Silent rate"
)
radar[, axis := match(endpoint_label, radar_order)]
radar <- radar[order(axis, example)]
radar[, endpoint_label := factor(endpoint_label, levels = rev(radar_order))]
radar[, prediction_label := formatC(prediction, digits = 3, format = "fg")]
radar[, label_hjust := fifelse(reference_percentile >= 75, 1.15, -0.15)]

p_radar <- ggplot(radar, aes(reference_percentile, endpoint_label, color = example)) +
  geom_vline(xintercept = c(25, 50, 75),
             color = c("#D7DEE8", "#9DAABD", "#D7DEE8"),
             linewidth = c(0.35, 0.55, 0.35)) +
  geom_line(aes(group = endpoint_label), color = "#D7DEE8", linewidth = 0.9) +
  geom_point(size = 2.8) +
  geom_text(aes(label = prediction_label, hjust = label_hjust),
            position = position_dodge(width = 0.35), vjust = -0.75,
            size = 2.25, show.legend = FALSE) +
  scale_x_continuous(limits = c(0, 100), breaks = seq(0, 100, 25),
                     labels = function(x) paste0(x, "%")) +
  scale_color_manual(values = sample_palette) +
  labs(
    title = "A  Contrasting continuous predictions",
    subtitle = "Position is the exact TCGA reference percentile; labels are original model predictions",
    x = "TCGA reference percentile", y = NULL, color = NULL
  ) +
  theme_minimal(base_size = 9.5, base_family = "Arial") +
  theme(
    panel.grid.major.y = element_blank(), panel.grid.minor = element_blank(),
    axis.text.y = element_text(size = 7.4, color = navy),
    plot.title = element_text(face = "bold", size = 13, color = navy),
    plot.subtitle = element_text(size = 8.5, color = muted),
    legend.position = "bottom", legend.text = element_text(size = 8.5),
    plot.margin = margin(8, 8, 8, 8)
  )

binary <- selected[outcome_type == "binary"]
binary[, endpoint_label := fcase(
  endpoint == "MSI-H strict (MANTIS >0.6)", "MSI-H strict (>0.6)",
  endpoint == "MSI-H (MANTIS >0.4)", "MSI-H (>0.4)",
  family == "driver_mutation", paste(endpoint, "mutation"),
  family == "oncogenic_pathway", paste(endpoint, "pathway"),
  default = endpoint
)]
binary[, endpoint_label := factor(endpoint_label,
                                  levels = rev(unique(endpoint_label[order(reference_percentile)])))]
p_binary <- ggplot(binary, aes(reference_percentile, endpoint_label, color = example)) +
  geom_vline(xintercept = 50, color = "#9DAABD", linewidth = 0.45, linetype = 2) +
  geom_line(aes(group = endpoint_label), color = "#D7DEE8", linewidth = 0.9) +
  geom_point(aes(shape = predicted_class), size = 3.1, stroke = 1) +
  scale_color_manual(values = sample_palette) +
  scale_shape_manual(values = c("0" = 1, "1" = 19),
                     labels = c("0" = "Negative call", "1" = "Positive call")) +
  scale_x_continuous(limits = c(0, 100), breaks = seq(0, 100, 25),
                     labels = function(x) paste0(x, "%")) +
  labs(
    title = "B  Binary calls separate the same examples",
    subtitle = "LDA-score percentile; filled points are positive calls, not probabilities",
    x = "Reference percentile", y = NULL, color = NULL, shape = NULL
  ) +
  theme_minimal(base_size = 9.5, base_family = "Arial") +
  theme(
    panel.grid.major.y = element_blank(), panel.grid.minor = element_blank(),
    axis.text.y = element_text(size = 7.5),
    plot.title = element_text(face = "bold", size = 13, color = navy),
    plot.subtitle = element_text(size = 8.5, color = muted),
    legend.position = "bottom", legend.box = "vertical",
    legend.text = element_text(size = 8.2)
  )

figure <- p_radar + p_binary +
  plot_annotation(
    title = "TITANPred converts one COAD feature vector into a multi-endpoint molecular profile",
    subtitle = "Examples were selected for maximal continuous-profile separation; this internal TCGA demonstration is not external validation.",
    caption = paste0("Example A (", example_map[example == "COAD example A", patient_id], "): MSI-, mutation-rate- and immune-high / aneuploidy-low. ",
                     "Example B (", example_map[example == "COAD example B", patient_id], "): aneuploidy-high / MSI- and immune-low. Binary scores are uncalibrated."),
    theme = theme(
      plot.title = element_text(face = "bold", size = 17, color = navy),
      plot.subtitle = element_text(size = 10, color = muted),
      plot.caption = element_text(size = 8.3, color = muted, hjust = 0)
    )
  )

ggsave("figures/Figure7_COAD_TITANPred_examples.png", figure,
       width = 13.2, height = 7.2, dpi = 320, bg = "white")
ggsave("figures/Figure7_COAD_TITANPred_examples.pdf", figure,
       width = 13.2, height = 7.2, device = cairo_pdf, bg = "white")

cat("Selected:", paste(example_map$patient_id, collapse = " and "), "\n")
cat("Reports:", paste(list.files("results/reports", pattern = "COAD_example", full.names = TRUE), collapse = "\n"), "\n")
