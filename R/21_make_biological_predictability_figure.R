suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(patchwork)
})

source("R/utils.R")

input_file <- "results/tables/foundation_model_translational_biological_synthesis.csv"
if (!file.exists(input_file)) {
  stop("Missing biological synthesis table: ", input_file)
}

atlas <- fread(input_file)
comparison <- fread("results/tables/foundation_model_target_comparison.csv")
expected_comparison_rows <- nrow(comparison)
endpoint_dictionary <- fread("results/tables/endpoint_dictionary.csv")
required_columns <- c(
  "outcome_type", "family", "tumor_type", "endpoint", "n",
  "measurement_class", "same_histology_modality", "tss_retention_class",
  "screening_positive_TITAN", "screening_positive_GigaSSL",
  "screening_positive_ProvGigaPath", "effect_TITAN", "effect_GigaSSL",
  "effect_ProvGigaPath"
)
missing_columns <- setdiff(required_columns, names(atlas))
if (length(missing_columns)) {
  stop("Biological synthesis table is missing: ", paste(missing_columns, collapse = ", "))
}

representation_colours <- c(
  TITAN = "#2B6CB0",
  GigaSSL = "#D97706",
  ProvGigaPath = "#17806D"
)
representation_labels <- c(
  TITAN = "TITAN",
  GigaSSL = "Giga-SSL",
  ProvGigaPath = "Prov-GigaPath"
)
ink <- "#263746"
muted <- "#65758B"
grid_colour <- "#E3E9EF"

provenance_keys <- c("outcome_type", "family", "tumor_type", "endpoint", "source")
provenance <- unique(endpoint_dictionary[, c(
  provenance_keys, "measurement_class", "same_histology_modality"
), with = FALSE])
comparison <- merge(
  comparison,
  provenance,
  by = provenance_keys,
  all.x = TRUE,
  sort = FALSE
)
if (nrow(comparison) != expected_comparison_rows ||
    anyNA(comparison$measurement_class)) {
  stop("The matched atlas did not join one-to-one with endpoint provenance")
}
comparison[, any_crossing := screening_positive_TITAN |
                             screening_positive_GigaSSL |
                             screening_positive_ProvGigaPath]
comparison[, all_three_crossing := screening_positive_TITAN &
                                   screening_positive_GigaSSL &
                                   screening_positive_ProvGigaPath]
comparison[, figure_class := fcase(
  measurement_class == "directly observed genomic alteration",
    "Direct genomic alterations",
  outcome_type == "binary" & measurement_class == "composite genomic-context score",
    "Composite genomic-context status",
  measurement_class == "sequencing-derived continuous burden",
    "Sequencing-derived burdens",
  measurement_class == "transcriptomic signature",
    "Transcriptomic signatures",
  measurement_class == "transcriptomic pathway score",
    "RNA-derived pathway activities",
  measurement_class == "computationally inferred immune-cell fraction",
    "Inferred immune-cell fractions",
  outcome_type == "continuous" & measurement_class == "composite genomic-context score",
    "Continuous genomic-context scores",
  default = NA_character_
)]

class_order <- c(
  "Direct genomic alterations",
  "Composite genomic-context status",
  "Sequencing-derived burdens",
  "Transcriptomic signatures",
  "RNA-derived pathway activities",
  "Inferred immune-cell fractions",
  "Continuous genomic-context scores"
)

breadth <- comparison[
  !is.na(figure_class) & same_histology_modality == FALSE,
  .(
    eligible = .N,
    at_least_one = sum(any_crossing),
    all_three = sum(all_three_crossing)
  ),
  by = figure_class
]
breadth_long <- melt(
  breadth,
  id.vars = c("figure_class", "eligible"),
  measure.vars = c("at_least_one", "all_three"),
  variable.name = "support_scope",
  value.name = "crossings"
)
breadth_long[, crossing_rate := 100 * crossings / eligible]
breadth_long[, count_label := sprintf("%d/%d", crossings, eligible)]
breadth_long[, figure_class := factor(figure_class, levels = rev(class_order))]
breadth_long[, support_scope := factor(
  support_scope,
  levels = c("at_least_one", "all_three"),
  labels = c("At least one representation", "All three representations")
)]

leadership <- comparison[
  !is.na(figure_class) & same_histology_modality == FALSE & any_crossing == TRUE,
  .N,
  by = .(figure_class, best_foundation_model)
]
leadership[, total := sum(N), by = figure_class]
leadership[, percentage := 100 * N / total]
leadership[, count_label := ifelse(percentage >= 7, as.character(N), "")]
leadership[, figure_class := factor(figure_class, levels = rev(class_order))]
leadership[, best_foundation_model := factor(
  best_foundation_model,
  levels = c("TITAN", "GigaSSL", "ProvGigaPath")
)]

theme_predictability <- function(base_size = 14) {
  theme_minimal(base_size = base_size, base_family = "Arial") +
    theme(
      text = element_text(colour = ink),
      panel.grid.minor = element_blank(),
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_line(colour = grid_colour, linewidth = 0.35),
      plot.title = element_text(face = "bold", colour = "#17324D", size = rel(1.05)),
      plot.subtitle = element_text(colour = muted, size = rel(0.83), margin = margin(b = 6)),
      plot.caption = element_text(colour = muted, hjust = 0, size = rel(0.74)),
      axis.title = element_text(face = "bold"),
      axis.text.y = element_text(size = rel(0.83)),
      legend.position = "bottom",
      legend.title = element_blank(),
      plot.margin = margin(6, 9, 6, 6)
    )
}

p_breadth <- ggplot(
  breadth_long,
  aes(crossing_rate, figure_class, fill = support_scope)
) +
  geom_col(
    position = position_dodge(width = 0.72),
    width = 0.62,
    colour = "white",
    linewidth = 0.35
  ) +
  geom_text(
    aes(label = sprintf("%s  (%.1f%%)", count_label, crossing_rate)),
    position = position_dodge(width = 0.72),
    hjust = -0.08,
    size = 3.05,
    colour = ink,
    show.legend = FALSE
  ) +
  scale_x_continuous(
    limits = c(0, 90),
    breaks = seq(0, 80, 20),
    labels = function(x) paste0(x, "%"),
    expand = expansion(mult = c(0, 0))
  ) +
  scale_fill_manual(values = c(
    "At least one representation" = "#334E68",
    "All three representations" = "#2A9D8F"
  )) +
  labs(
    x = "Eligible pairs reaching threshold (%)",
    y = NULL,
    title = "A  Histology-predictable tumour-feature classes",
    subtitle = "Crossings/eligible pairs; 11 same-H&E TIL tasks excluded."
  ) +
  theme_predictability(14) +
  theme(
    legend.position = "top",
    legend.justification = "left",
    legend.text = element_text(size = 11.5),
    panel.grid.major.x = element_line(colour = grid_colour, linewidth = 0.35),
    axis.text.y = element_text(size = 11.0)
  ) +
  guides(fill = guide_legend(nrow = 1, byrow = TRUE))

p_leadership <- ggplot(
  leadership,
  aes(percentage, figure_class, fill = best_foundation_model)
) +
  geom_col(
    width = 0.68, colour = "white", linewidth = 0.35,
    position = position_stack(reverse = TRUE)
  ) +
  geom_text(
    aes(label = count_label),
    position = position_stack(vjust = 0.5, reverse = TRUE),
    colour = "white",
    fontface = "bold",
    size = 4.0,
    family = "Arial"
  ) +
  scale_x_continuous(
    breaks = seq(0, 100, 20),
    labels = function(x) paste0(x, "%"),
    expand = expansion(mult = c(0, 0))
  ) +
  coord_cartesian(xlim = c(0, 100), clip = "off") +
  scale_fill_manual(
    values = representation_colours,
    breaks = names(representation_labels),
    labels = representation_labels
  ) +
  labs(
    x = "Pairs for which the representation had the highest observed effect",
    y = NULL,
    title = "Leading representation by tumour-feature class",
    subtitle = "485 cross-modal threshold-crossing pairs; numbers are cancer-endpoint pair counts.",
    caption = paste0(
      "Leader = highest patient-level out-of-fold Q-squared or AUROC under the common PLS-based probe.\n",
      "This descriptive rank does not test intrinsic model superiority."
    )
  ) +
  theme_predictability(15) +
  theme(
    legend.position = "bottom",
    legend.text = element_text(size = 12.5),
    axis.text.y = element_text(size = 12.2),
    plot.caption = element_text(size = 10.2, margin = margin(t = 7))
  ) +
  guides(fill = guide_legend(nrow = 1, byrow = TRUE))

# Select examples deterministically from the refreshed atlas. One leading
# example per endpoint family/provenance class is selected first, then the
# remaining positions are filled by the minimum effect across representations.
# This avoids stale hand-picked targets after a package or analysis refresh.
select_diverse_examples <- function(d, group_column, n_examples = 9L) {
  d <- copy(d)
  setorder(d, -minimum_primary_effect, tumor_type, endpoint)
  anchors <- d[, .SD[1L], by = group_column]
  selected <- unique(rbindlist(list(anchors, d), use.names = TRUE),
                     by = c("outcome_type", "family", "tumor_type", "endpoint", "source"))
  selected[seq_len(min(n_examples, nrow(selected)))]
}

binary_selected <- select_diverse_examples(
  atlas[outcome_type == "binary"], "family"
)
continuous_selected <- select_diverse_examples(
  atlas[outcome_type == "continuous" & same_histology_modality == FALSE],
  "measurement_class"
)
if (nrow(binary_selected) < 9L || nrow(continuous_selected) < 9L) {
  stop("Fewer than nine stable all-three biological examples are available")
}
binary_selected[, display_label := sprintf(
  "%s: %s%s", tumor_type, endpoint,
  fifelse(family == "driver_mutation", " mutation", "")
)]
readable_endpoint <- function(x) {
  hallmark <- startsWith(x, "HALLMARK_")
  x[hallmark] <- sub("^HALLMARK_", "", x[hallmark])
  x[hallmark] <- tools::toTitleCase(tolower(gsub("_", " ", x[hallmark])))
  x <- sub("Epithelial Mesenchymal Transition",
           "Epithelial-mesenchymal transition", x, fixed = TRUE)
  x
}
continuous_selected[, display_label := sprintf(
  "%s: %s", tumor_type, readable_endpoint(endpoint)
)]
binary_selected[, display_order := rev(seq_len(.N))]
continuous_selected[, display_order := rev(seq_len(.N))]

to_plot_long <- function(selected) {
  selected[, value_label := sprintf(
    "%.3f / %.3f / %.3f",
    effect_TITAN, effect_GigaSSL, effect_ProvGigaPath
  )]
  selected[, best_representation := c("TITAN", "GigaSSL", "ProvGigaPath")[
    max.col(cbind(effect_TITAN, effect_GigaSSL, effect_ProvGigaPath), ties.method = "first")
  ]]
  selected[, best_label := fifelse(
    best_representation == "ProvGigaPath", "Prov-GP",
    unname(representation_labels[best_representation])
  )]
  long <- melt(
    selected,
    id.vars = c(
      "display_label", "display_order", "n", "value_label",
      "best_representation", "best_label"
    ),
    measure.vars = c("effect_TITAN", "effect_GigaSSL", "effect_ProvGigaPath"),
    variable.name = "representation",
    value.name = "effect"
  )
  long[, representation := sub("effect_", "", representation)]
  long[, display_label := factor(
    sprintf("%s  (n=%d)", display_label, n),
    levels = sprintf("%s  (n=%d)",
                     selected[order(display_order), display_label],
                     selected[order(display_order), n])
  )]
  long
}

binary_long <- to_plot_long(binary_selected)
continuous_long <- to_plot_long(continuous_selected)

effect_plot <- function(data, threshold, x_limits, breaks, label_x, best_label_x,
                        title, subtitle, x_title) {
  ranges <- data[, .(
    xmin = min(effect), xmax = max(effect), value_label = first(value_label),
    best_representation = first(best_representation), best_label = first(best_label)
  ),
                 by = display_label]
  ggplot(data, aes(effect, display_label, colour = representation)) +
    geom_vline(xintercept = threshold, linetype = 3, linewidth = 0.6, colour = "#7B8794") +
    geom_segment(
      data = ranges,
      aes(x = xmin, xend = xmax, y = display_label, yend = display_label),
      inherit.aes = FALSE,
      colour = "#BBC6D1",
      linewidth = 1.0
    ) +
    geom_point(size = 3.1, stroke = 0.4) +
    geom_text(
      data = ranges,
      aes(x = label_x, y = display_label, label = value_label),
      inherit.aes = FALSE,
      hjust = 0,
      size = 3.35,
      colour = ink,
      family = "Arial"
    ) +
    geom_text(
      data = ranges,
      aes(
        x = best_label_x, y = display_label,
        label = best_label, colour = best_representation
      ),
      inherit.aes = FALSE,
      hjust = 0,
      size = 3.35,
      fontface = "bold",
      family = "Arial",
      show.legend = FALSE
    ) +
    scale_x_continuous(limits = x_limits, breaks = breaks, expand = expansion(mult = c(0, 0))) +
    scale_colour_manual(
      values = representation_colours,
      breaks = names(representation_labels),
      labels = representation_labels
    ) +
    labs(x = x_title, y = NULL, title = title, subtitle = subtitle) +
    theme_predictability(14) +
    theme(legend.position = "none")
}

p_binary <- effect_plot(
  binary_long,
  threshold = 0.60,
  x_limits = c(0.55, 1.44),
  breaks = seq(0.60, 1.00, 0.10),
  label_x = 1.02,
  best_label_x = 1.28,
  title = "B  Genomic and genomic-context examples",
  subtitle = "Values: TITAN / Giga-SSL / Prov-GigaPath.",
  x_title = "Patient-level out-of-fold AUROC"
)

p_continuous <- effect_plot(
  continuous_long,
  threshold = 0.20,
  x_limits = c(0.15, 1.16),
  breaks = seq(0.20, 0.70, 0.10),
  label_x = 0.70,
  best_label_x = 1.00,
  title = "C  Pathway, immune and tissue-context examples",
  subtitle = "RNA-derived or inferred reference phenotypes; values: TITAN / Giga-SSL / Prov-GigaPath.",
  x_title = "Patient-level out-of-fold Q-squared"
)

p_binary <- p_binary +
  theme(legend.position = "bottom", legend.text = element_text(size = 11.5)) +
  guides(colour = guide_legend(nrow = 1, byrow = TRUE))

figure <- p_breadth / p_binary / p_continuous +
  plot_layout(heights = c(0.94, 1.18, 1.10)) +
  plot_annotation(theme = theme(plot.margin = margin(8, 14, 24, 8)))

dir.create("results/figures", recursive = TRUE, showWarnings = FALSE)
dir.create("figures", recursive = TRUE, showWarnings = FALSE)
for (path in c(
  "results/figures/Figure2_biological_predictability_map.png",
  "figures/Figure2_biological_predictability_map.png"
)) {
  ggsave(path, figure, width = 10.4, height = 10.4, dpi = 360, bg = "white")
}

for (path in c(
  "results/figures/Figure3_foundation_model_leadership.png",
  "figures/Figure3_foundation_model_leadership.png"
)) {
  ggsave(path, p_leadership, width = 9.6, height = 4.8, dpi = 360, bg = "white")
}

fwrite(
  breadth[match(class_order, figure_class)],
  "results/tables/foundation_model_biological_predictability_breadth.csv"
)
fwrite(
  leadership[order(figure_class, best_foundation_model)],
  "results/tables/foundation_model_biological_predictability_leadership.csv"
)
fwrite(
  rbindlist(list(
    binary_selected[, .(outcome_type = "binary", tumor_type, family, endpoint,
                         display_label, n, effect_TITAN, effect_GigaSSL,
                         effect_ProvGigaPath, tss_retention_class)],
    continuous_selected[, .(outcome_type = "continuous", tumor_type, family, endpoint,
                             display_label, n, effect_TITAN, effect_GigaSSL,
                             effect_ProvGigaPath, tss_retention_class)]
  ), fill = TRUE),
  "results/tables/foundation_model_biological_predictability_examples.csv"
)

message("Wrote biological predictability and foundation-model leadership figures and source tables")
