#!/usr/bin/env Rscript

# Build a threshold-light presentation layer from already completed matched
# analyses.  This script does not refit any model.  It combines continuous
# performance estimates, alternative-partition variability, rank stability,
# and tissue-source-site-code grouped versus matched-random effects.

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(patchwork)
})

dir.create("results/tables", recursive = TRUE, showWarnings = FALSE)
dir.create("results/figures", recursive = TRUE, showWarnings = FALSE)
dir.create("figures", recursive = TRUE, showWarnings = FALSE)

keys <- c("outcome_type", "family", "subfamily", "tumor_type", "endpoint", "source")
rep_levels <- c("TITAN", "GigaSSL", "ProvGigaPath")
rep_labels <- c(TITAN = "TITAN", GigaSSL = "Giga-SSL", ProvGigaPath = "Prov-GigaPath")
rep_cols <- c(TITAN = "#2B6CB0", GigaSSL = "#D97706", ProvGigaPath = "#17806D")

primary <- read.csv("results/tables/foundation_model_matched_screen.csv", check.names = FALSE)
repeats <- read.csv("results/tables/foundation_model_fold_stability_repeats.csv", check.names = FALSE)
grouped <- read.csv("results/tables/foundation_model_tss_grouped_sensitivity.csv", check.names = FALSE)
winners <- read.csv("results/tables/foundation_model_winner_stability.csv", check.names = FALSE)

primary <- primary %>%
  mutate(
    primary_effect = ifelse(outcome_type == "continuous", q2, auc),
    primary_operating_metric = ifelse(outcome_type == "continuous", q2, auc)
  ) %>%
  select(all_of(keys), foundation_model, n, positive, negative,
         primary_effect, primary_operating_metric)

repeat_summary <- repeats %>%
  group_by(across(all_of(c(keys, "foundation_model")))) %>%
  summarise(
    alternative_partitions = n(),
    repeat_effect_median = median(effect, na.rm = TRUE),
    repeat_effect_q25 = quantile(effect, 0.25, na.rm = TRUE, names = FALSE),
    repeat_effect_q75 = quantile(effect, 0.75, na.rm = TRUE, names = FALSE),
    crossing_proportion = mean(crossing, na.rm = TRUE),
    .groups = "drop"
  )

grouped_summary <- grouped %>%
  transmute(
    across(all_of(keys)), foundation_model,
    grouped_effect, matched_random_effect, grouped_minus_matched_effect
  )

winner_summary <- winners %>%
  select(all_of(keys), primary_best_foundation_model,
         primary_winner_repeat_proportion, modal_repeat_winner,
         modal_repeat_winner_proportion)

audit <- primary %>%
  inner_join(repeat_summary, by = c(keys, "foundation_model")) %>%
  left_join(grouped_summary, by = c(keys, "foundation_model")) %>%
  left_join(winner_summary, by = keys) %>%
  mutate(
    sample_size_stratum = case_when(
      outcome_type == "continuous" & n >= 100 ~ "larger-sample",
      outcome_type == "binary" & positive >= 50 & negative >= 50 ~ "larger-sample",
      TRUE ~ "smaller-sample"
    ),
    foundation_model = factor(foundation_model, levels = rep_levels),
    representation = rep_labels[as.character(foundation_model)]
  )

write.csv(audit,
          "results/tables/foundation_model_effect_partition_audit.csv",
          row.names = FALSE, na = "")

theme_atlas <- theme_minimal(base_size = 14) +
  theme(
    plot.title = element_text(face = "bold", size = 15),
    plot.subtitle = element_text(size = 11.5, colour = "#444444"),
    strip.text = element_text(face = "bold"),
    legend.position = "bottom",
    panel.grid.minor = element_blank()
  )

p1 <- ggplot(audit, aes(primary_effect, repeat_effect_median,
                        colour = foundation_model)) +
  geom_abline(slope = 1, intercept = 0, colour = "#777777", linewidth = 0.45,
              linetype = "dashed") +
  geom_errorbar(aes(ymin = repeat_effect_q25, ymax = repeat_effect_q75),
                alpha = 0.18, linewidth = 0.25, width = 0) +
  geom_point(alpha = 0.45, size = 1.65) +
  facet_wrap(~ outcome_type, scales = "free") +
  scale_colour_manual(values = rep_cols, labels = rep_labels) +
  labs(
    title = "A  Primary and alternative-partition effects",
    subtitle = "Q2 for continuous pairs; AUROC for binary pairs. Bars show the repeat interquartile range.",
    x = "Primary-partition effect", y = "Median effect across five alternative partitions",
    colour = "Representation"
  ) + theme_atlas

grouped_plot <- audit %>% filter(!is.na(grouped_effect), !is.na(matched_random_effect))
p2 <- ggplot(grouped_plot, aes(matched_random_effect, grouped_effect,
                              colour = foundation_model)) +
  geom_abline(slope = 1, intercept = 0, colour = "#777777", linewidth = 0.45,
              linetype = "dashed") +
  geom_point(alpha = 0.52, size = 1.75) +
  facet_wrap(~ outcome_type, scales = "free") +
  scale_colour_manual(values = rep_cols, labels = rep_labels) +
  labs(
    title = "B  Grouped effects versus matched-random partitions",
    subtitle = "Q2 for continuous pairs; AUROC for binary pairs. The identity line indicates equal performance.",
    x = "Matched-random effect", y = "Tissue-source-site-code-grouped effect",
    colour = "Representation"
  ) + theme_atlas

winner_plot <- winner_summary %>%
  mutate(outcome_type = factor(outcome_type, levels = c("continuous", "binary")))
p3 <- ggplot(winner_plot, aes(outcome_type, primary_winner_repeat_proportion,
                             fill = outcome_type)) +
  geom_violin(trim = TRUE, alpha = 0.65, colour = NA, width = 0.82) +
  geom_boxplot(width = 0.18, outlier.shape = NA, fill = "white", linewidth = 0.5) +
  geom_jitter(width = 0.10, alpha = 0.20, size = 0.75) +
  scale_fill_manual(values = c(continuous = "#4C78A8", binary = "#B45F06")) +
  scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
  labs(
    title = "Stability of the primary leading-representation rank",
    subtitle = "Proportion of five alternative partitions retaining the primary leading representation.",
    x = NULL, y = "Primary winner repeat proportion"
  ) + theme_atlas + theme(legend.position = "none")

fig <- p1 / p2 + plot_layout(heights = c(1, 1))
out <- "results/figures/Figure3_effect_partition_stability.png"
ggsave(out, fig, width = 10.5, height = 10.2, dpi = 320, bg = "white")
file.copy(out, "figures/Figure3_effect_partition_stability.png", overwrite = TRUE)
ggsave("results/figures/FigureS13_winner_rank_stability.png", p3,
       width = 8.5, height = 5.2, dpi = 320, bg = "white")
file.copy("results/figures/FigureS13_winner_rank_stability.png",
          "figures/FigureS13_winner_rank_stability.png", overwrite = TRUE)

message("Wrote ", nrow(audit), " representation-task audit rows and ", out)
