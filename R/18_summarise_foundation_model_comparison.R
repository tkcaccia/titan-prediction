suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(patchwork)
})

x <- fread("results/tables/foundation_model_matched_screen.csv")
# AUROC is the primary binary representation-comparison statistic. The same
# AUROC estimand defines the descriptive binary crossing rule.
x[, effect := fifelse(outcome_type == "continuous", q2, auc)]
x[, screening_positive := fifelse(outcome_type == "continuous", q2 >= 0.20,
                                  auc >= 0.60)]
x[, screening_tier_A := fifelse(outcome_type == "continuous", q2 >= 0.40,
                                auc >= 0.70)]

# Join endpoint provenance at the exact cancer-endpoint-source level. This
# separates directly observed genomic alterations from sequencing-derived
# burdens, computational immune phenotypes, transcriptomic signatures,
# same-H&E quantities and composite genomic-context scores.
provenance_map <- unique(fread(
  "results/tables/endpoint_dictionary.csv"
)[, .(outcome_type, family, tumor_type, endpoint, source,
      measurement_class, source_modality, direct_vs_inferred,
      same_histology_modality, definition_group)])
x <- merge(x, provenance_map,
           by = c("outcome_type", "family", "tumor_type", "endpoint", "source"),
           all.x = TRUE, sort = FALSE)
stopifnot(!anyNA(x$measurement_class), !anyNA(x$same_histology_modality))

summary <- x[, .(
  eligible_targets = .N,
  screening_positive = sum(screening_positive, na.rm = TRUE),
  screening_tier_A = sum(screening_tier_A, na.rm = TRUE),
  median_effect = median(effect, na.rm = TRUE),
  median_q2 = median(q2, na.rm = TRUE),
  median_balanced_accuracy = median(balanced_accuracy, na.rm = TRUE),
  median_auc = median(auc, na.rm = TRUE),
  median_pr_auc = median(pr_auc, na.rm = TRUE)
), by = .(foundation_model, outcome_type)]
fwrite(summary, "results/tables/foundation_model_matched_summary.csv")

id <- c("outcome_type", "family", "subfamily", "tumor_type", "endpoint",
        "source", "n", "positive", "negative")
wide <- dcast(x, paste(paste(id, collapse = " + "), "~ foundation_model"),
              value.var = c("effect", "screening_positive", "q2", "rmse",
                            "spearman", "balanced_accuracy", "auc", "pr_auc",
                            "sensitivity", "specificity", "ppv", "npv",
                            "prevalence", "no_skill_pr_auc"))
wide[, supported_by_n := rowSums(.SD, na.rm = TRUE),
     .SDcols = patterns("^screening_positive_")]
wide[, support_pattern := paste0(
  fifelse(screening_positive_TITAN, "TITAN", ""),
  fifelse(screening_positive_GigaSSL, "+GigaSSL", ""),
  fifelse(screening_positive_ProvGigaPath, "+ProvGigaPath", "")
)]
wide[, support_pattern := sub("^\\+", "", support_pattern)]
wide[support_pattern == "", support_pattern := "None"]
wide[, best_foundation_model := c("GigaSSL", "ProvGigaPath", "TITAN")[
  max.col(cbind(effect_GigaSSL, effect_ProvGigaPath, effect_TITAN),
          ties.method = "first")
]]
fwrite(wide, "results/tables/foundation_model_target_comparison.csv")

pairwise <- rbindlist(lapply(c("GigaSSL", "ProvGigaPath"), function(other) {
  wide[, .(
    targets = .N,
    spearman_effect = cor(get(paste0("effect_", other)), effect_TITAN,
                          method = "spearman", use = "complete.obs"),
    median_delta_vs_TITAN = median(get(paste0("effect_", other)) - effect_TITAN,
                                   na.rm = TRUE),
    other_higher = sum(get(paste0("effect_", other)) > effect_TITAN, na.rm = TRUE),
    TITAN_higher = sum(effect_TITAN > get(paste0("effect_", other)), na.rm = TRUE),
    tied = sum(effect_TITAN == get(paste0("effect_", other)), na.rm = TRUE)
  ), by = outcome_type][, comparison := paste(other, "versus TITAN")]
}))
set.seed(20260824L)
pairwise_ci <- rbindlist(lapply(c("GigaSSL", "ProvGigaPath"), function(other) {
  rbindlist(lapply(c("binary", "continuous"), function(type) {
    d <- wide[outcome_type == type, .(
      tumor_type,
      delta = get(paste0("effect_", other)) - effect_TITAN
    )]
    cancers <- unique(d$tumor_type)
    delta_by_cancer <- split(d$delta, factor(d$tumor_type, levels = cancers))
    boot <- replicate(5000L, {
      sampled <- sample.int(length(cancers), length(cancers), replace = TRUE)
      median(unlist(delta_by_cancer[sampled], use.names = FALSE), na.rm = TRUE)
    })
    data.table(
      comparison = paste(other, "versus TITAN"), outcome_type = type,
      cluster_bootstrap_low = unname(quantile(boot, 0.025, na.rm = TRUE)),
      cluster_bootstrap_high = unname(quantile(boot, 0.975, na.rm = TRUE)),
      uncertainty_method = "cancer-cluster bootstrap of median paired task effects; descriptive"
    )
  }))
}))
pairwise <- merge(pairwise, pairwise_ci,
                  by = c("comparison", "outcome_type"), all.x = TRUE, sort = FALSE)
setcolorder(pairwise, c("comparison", "outcome_type", setdiff(names(pairwise),
                                                               c("comparison", "outcome_type"))))
fwrite(pairwise, "results/tables/foundation_model_pairwise_summary.csv")

family_summary <- x[, .(
  eligible_tasks = .N,
  effect_threshold_crossings = sum(screening_positive, na.rm = TRUE),
  crossing_percent = 100 * mean(screening_positive, na.rm = TRUE),
  median_effect = median(effect, na.rm = TRUE)
), by = .(foundation_model, outcome_type, family)]
fwrite(family_summary, "results/tables/foundation_model_family_summary.csv")

cancer_summary <- x[, .(
  eligible_tasks = .N,
  effect_threshold_crossings = sum(screening_positive, na.rm = TRUE),
  crossing_percent = 100 * mean(screening_positive, na.rm = TRUE),
  median_effect = median(effect, na.rm = TRUE)
), by = .(foundation_model, outcome_type, tumor_type)]
fwrite(cancer_summary, "results/tables/foundation_model_cancer_summary.csv")

# Catalogue-normalised breadth summaries. A task is one cancer-endpoint pair;
# endpoint definitions collapse the same endpoint repeated across cancers.
# Macro rates are unweighted means of within-family or within-cancer crossing
# percentages, so families/cancers with many eligible tasks do not dominate.
endpoint_coverage <- x[, .(
  eligible_endpoint_definitions = uniqueN(paste(family, endpoint, source,
                                                 sep = "\r")),
  endpoint_definitions_crossing = uniqueN(paste(
    family[screening_positive == TRUE], endpoint[screening_positive == TRUE],
    source[screening_positive == TRUE], sep = "\r"
  ))
), by = .(foundation_model, outcome_type)]
endpoint_coverage[, endpoint_definition_crossing_percent :=
                    100 * endpoint_definitions_crossing /
                      eligible_endpoint_definitions]

family_macro <- family_summary[, .(
  macro_family_crossing_percent = mean(crossing_percent),
  evaluated_families = .N
), by = .(foundation_model, outcome_type)]
cancer_macro <- cancer_summary[, .(
  macro_cancer_crossing_percent = mean(crossing_percent),
  evaluated_cancers = .N
), by = .(foundation_model, outcome_type)]
largest_family <- x[screening_positive == TRUE, .N,
  by = .(foundation_model, outcome_type, family)]
setorder(largest_family, foundation_model, outcome_type, -N, family)
largest_family <- largest_family[, .SD[1L],
  by = .(foundation_model, outcome_type)]
setnames(largest_family, c("family", "N"),
         c("largest_crossing_family", "largest_family_crossings"))

normalised_breadth <- merge(
  summary[, .(
    foundation_model, outcome_type,
    eligible_tasks = eligible_targets,
    task_crossings = screening_positive,
    task_crossing_percent = 100 * screening_positive / eligible_targets
  )], endpoint_coverage,
  by = c("foundation_model", "outcome_type")
)
normalised_breadth <- merge(normalised_breadth, family_macro,
  by = c("foundation_model", "outcome_type"))
normalised_breadth <- merge(normalised_breadth, cancer_macro,
  by = c("foundation_model", "outcome_type"))
normalised_breadth <- merge(normalised_breadth, largest_family,
  by = c("foundation_model", "outcome_type"))
normalised_breadth[, largest_family_share_of_crossings :=
                     100 * largest_family_crossings / task_crossings]
fwrite(normalised_breadth,
       "results/tables/foundation_model_normalized_breadth_summary.csv")
fwrite(endpoint_coverage,
       "results/tables/foundation_model_endpoint_definition_coverage.csv")

# Parallel provenance-class summaries and the same-H&E exclusion sensitivity.
provenance_summary <- x[, .(
  eligible_tasks = .N,
  effect_threshold_crossings = sum(screening_positive),
  crossing_percent = 100 * mean(screening_positive),
  unique_endpoint_definitions = uniqueN(paste(family, endpoint, source,
                                               sep = "\r")),
  unique_definitions_crossing = uniqueN(paste(
    family[screening_positive == TRUE], endpoint[screening_positive == TRUE],
    source[screening_positive == TRUE], sep = "\r"
  )),
  median_effect = median(effect, na.rm = TRUE)
), by = .(foundation_model, outcome_type, measurement_class,
          same_histology_modality)]
provenance_summary[, unique_definition_crossing_percent :=
                     100 * unique_definitions_crossing /
                       unique_endpoint_definitions]
setorder(provenance_summary, outcome_type, measurement_class,
         foundation_model)
fwrite(provenance_summary,
       "results/tables/foundation_model_provenance_stratified_summary.csv")

same_histology_sensitivity <- x[outcome_type == "continuous", .(
  full_titan_universe_same_histology_tasks = 13L,
  matched_same_histology_tasks = sum(same_histology_modality),
  all_continuous_tasks = .N,
  all_continuous_crossings = sum(screening_positive),
  all_continuous_crossing_percent = 100 * mean(screening_positive),
  same_histology_crossings = sum(screening_positive & same_histology_modality),
  cross_modal_continuous_tasks = sum(!same_histology_modality),
  cross_modal_continuous_crossings = sum(screening_positive &
                                           !same_histology_modality),
  cross_modal_continuous_crossing_percent = 100 * mean(
    screening_positive[!same_histology_modality]
  ),
  all_matched_tasks = x[foundation_model == .BY$foundation_model, .N],
  all_matched_crossings = sum(screening_positive) +
    x[foundation_model == .BY$foundation_model & outcome_type == "binary",
      sum(screening_positive)],
  matched_tasks_excluding_same_histology =
    x[foundation_model == .BY$foundation_model, .N] -
      sum(same_histology_modality),
  matched_crossings_excluding_same_histology =
    sum(screening_positive & !same_histology_modality) +
    x[foundation_model == .BY$foundation_model & outcome_type == "binary",
      sum(screening_positive)]
), by = foundation_model]
fwrite(same_histology_sensitivity,
       "results/tables/foundation_model_same_histology_sensitivity.csv")

endpoint_cancer_retention <- x[, .(
  eligible_cancers = uniqueN(tumor_type),
  retained_cancers = uniqueN(tumor_type[screening_positive == TRUE]),
  retained_cancer_percent = 100 * uniqueN(tumor_type[screening_positive == TRUE]) /
    uniqueN(tumor_type),
  retained_cancer_codes = paste(sort(unique(tumor_type[screening_positive == TRUE])),
                                collapse = ";")
), by = .(foundation_model, outcome_type, family, endpoint, source)]
setorder(endpoint_cancer_retention, outcome_type, family, endpoint,
         foundation_model)
fwrite(endpoint_cancer_retention,
       "results/tables/foundation_model_endpoint_cancer_retention.csv")

x_programme <- copy(x)
x_programme[is.na(definition_group) | !nzchar(definition_group),
            definition_group := endpoint]
programme_cancer_retention <- x_programme[, .(
  eligible_cancers = uniqueN(tumor_type),
  retained_cancers = uniqueN(tumor_type[screening_positive == TRUE]),
  retained_cancer_percent = 100 * uniqueN(tumor_type[screening_positive == TRUE]) /
    uniqueN(tumor_type),
  retained_cancer_codes = paste(sort(unique(tumor_type[screening_positive == TRUE])),
                                collapse = ";")
), by = .(foundation_model, outcome_type, family, definition_group)]
setorder(programme_cancer_retention, outcome_type, family, definition_group,
         foundation_model)
fwrite(programme_cancer_retention,
       "results/tables/foundation_model_programme_cancer_retention.csv")

# Translational synthesis: strongest mature, all-three, complete-grouped-
# retention examples within each provenance class. Ranking uses the minimum
# effect across the three representations so it cannot be driven by one model.
robustness_path <-
  "results/tables/foundation_model_internal_robustness_classification.csv"
tss_path <- "results/tables/foundation_model_tss_grouped_sensitivity.csv"
if (file.exists(robustness_path) && file.exists(tss_path)) {
  robustness <- fread(robustness_path)
  tss <- fread(tss_path)
  tss_wide <- dcast(tss,
    outcome_type + family + tumor_type + endpoint + source ~ foundation_model,
    value.var = "grouped_effect")
  setnames(tss_wide, c("GigaSSL", "ProvGigaPath", "TITAN"),
           c("grouped_effect_GigaSSL", "grouped_effect_ProvGigaPath",
             "grouped_effect_TITAN"))
  synthesis <- merge(wide, provenance_map,
    by = c("outcome_type", "family", "tumor_type", "endpoint", "source"),
    all.x = TRUE, sort = FALSE)
  synthesis <- merge(synthesis, robustness[, .(
    outcome_type, family, tumor_type, endpoint, source,
    primary_consensus_class, sample_size_maturity, tss_retention_class,
    internal_robustness_class
  )], by = c("outcome_type", "family", "tumor_type", "endpoint", "source"),
    all.x = TRUE, sort = FALSE)
  synthesis <- merge(synthesis, tss_wide,
    by = c("outcome_type", "family", "tumor_type", "endpoint", "source"),
    all.x = TRUE, sort = FALSE)
  synthesis[, minimum_primary_effect := pmin(effect_TITAN, effect_GigaSSL,
                                              effect_ProvGigaPath)]
  synthesis[, mean_primary_effect := rowMeans(.SD),
            .SDcols = c("effect_TITAN", "effect_GigaSSL",
                        "effect_ProvGigaPath")]
  synthesis <- synthesis[
    primary_consensus_class == "all three" & sample_size_maturity == TRUE &
      tss_retention_class == "complete retention"
  ]
  setorder(synthesis, measurement_class, -minimum_primary_effect,
           tumor_type, endpoint)
  synthesis[, provenance_rank := seq_len(.N), by = measurement_class]
  synthesis[, interpretation_scope := fcase(
    measurement_class == "directly observed genomic alteration",
      "association with a directly observed sequence-based alteration",
    measurement_class == "sequencing-derived continuous burden",
      "agreement with a sequencing-derived continuous burden",
    measurement_class == "computationally inferred immune-cell fraction",
      "agreement with a computationally inferred immune phenotype; not recovery of cell abundance",
    measurement_class == "transcriptomic signature",
      "agreement with a bulk-transcriptomic signature",
    measurement_class == "transcriptomic pathway score",
      "agreement with a bulk-transcriptomic pathway activity score",
    measurement_class == "pathology-associated quantity",
      "same-H&E computational concordance; not cross-modal molecular prediction",
    measurement_class == "composite genomic-context score",
      "agreement with a composite genomic-context phenotype"
  )]
  fwrite(synthesis,
         "results/tables/foundation_model_translational_biological_synthesis.csv")
} else {
  message("Grouped robustness inputs are not available yet; ",
          "the later summary pass will create the translational synthesis.")
}

concordance_summary <- wide[, .(
  tasks = .N
), by = .(outcome_type, support_category = fcase(
  supported_by_n == 3L, "effect-threshold crossing in all three",
  supported_by_n == 2L, "effect-threshold crossing in two",
  supported_by_n == 1L, "effect-threshold crossing in one",
  default = "no effect-threshold crossing"
))]
fwrite(concordance_summary, "results/tables/foundation_model_concordance_summary.csv")

wide[, effect_range := pmax(effect_GigaSSL, effect_ProvGigaPath, effect_TITAN,
                            na.rm = TRUE) -
                       pmin(effect_GigaSSL, effect_ProvGigaPath, effect_TITAN,
                            na.rm = TRUE)]
discordant <- wide[effect_range >= 0.20]
setorder(discordant, outcome_type, -effect_range)
discordant[, discordance_rank := seq_len(.N), by = outcome_type]
fwrite(discordant, "results/tables/foundation_model_strongly_discordant_targets.csv")

colours <- c(TITAN = "#2B6CB0", GigaSSL = "#D97706", ProvGigaPath = "#17806D")
provenance_plot <- copy(provenance_summary)
provenance_plot[, label_class := fcase(
  measurement_class == "directly observed genomic alteration",
    "Direct genomic alterations",
  measurement_class == "sequencing-derived continuous burden",
    "Sequencing-derived burdens",
  measurement_class == "computationally inferred immune-cell fraction",
    "Inferred immune-cell fractions",
  measurement_class == "transcriptomic signature",
    "Transcriptomic signatures",
  measurement_class == "transcriptomic pathway score",
    "RNA-derived pathway activities",
  measurement_class == "pathology-associated quantity",
    "Same-H&E TIL fraction",
  measurement_class == "composite genomic-context score" & outcome_type == "binary",
    "Composite genomic-context status",
  measurement_class == "composite genomic-context score",
    "Composite genomic-context scores"
)]
provenance_levels <- rev(c(
  "Direct genomic alterations", "Composite genomic-context status",
  "Sequencing-derived burdens", "Transcriptomic signatures",
  "RNA-derived pathway activities", "Inferred immune-cell fractions",
  "Composite genomic-context scores",
  "Same-H&E TIL fraction"
))
provenance_plot[, label_class := factor(label_class, levels = provenance_levels)]
provenance_plot[, label := sprintf("%.1f%% (%d/%d)", crossing_percent,
                                  effect_threshold_crossings, eligible_tasks)]
# Place mid-to-high values to the left of their point so the count label stays
# inside the facet at journal page width. Lower values remain right-aligned.
provenance_plot[, label_hjust := fifelse(crossing_percent >= 48, 1.06, -0.08)]
p1 <- ggplot(provenance_plot,
             aes(crossing_percent, label_class, colour = foundation_model,
                 group = foundation_model)) +
  geom_point(position = position_dodge(width = 0.62), size = 3.2) +
  geom_text(aes(label = label, hjust = label_hjust),
            position = position_dodge(width = 0.62),
            size = 3.25, show.legend = FALSE) +
  facet_wrap(~ outcome_type, nrow = 1, scales = "free_y") +
  scale_x_continuous(limits = c(0, 105), breaks = seq(0, 100, 20),
                     labels = function(z) paste0(z, "%")) +
  scale_colour_manual(
    values = colours,
    breaks = c("TITAN", "GigaSSL", "ProvGigaPath"),
    labels = c(GigaSSL = "Giga-SSL", ProvGigaPath = "Prov-GigaPath",
               TITAN = "TITAN")
  ) +
  labs(x = "Effect-threshold crossing rate within provenance class", y = NULL,
       title = "Reference-label provenance is reported before aggregate breadth",
       colour = NULL) +
  theme_minimal(base_size = 13.5) +
  theme(legend.position = "top", panel.grid.major.y = element_blank(),
        axis.text.y = element_text(size = 11.2),
        strip.text = element_text(face = "bold"),
        plot.title = element_text(face = "bold", size = 14),
        plot.subtitle = element_text(size = 10.5))

long <- melt(wide,
             id.vars = c("outcome_type", "family", "tumor_type", "endpoint",
                         "effect_TITAN"),
             measure.vars = c("effect_GigaSSL", "effect_ProvGigaPath"),
             variable.name = "comparison", value.name = "other_effect")
long[, comparison := sub("effect_", "", comparison)]
long[, comparison_label := factor(comparison,
  levels = c("GigaSSL", "ProvGigaPath"), labels = c("Giga-SSL", "Prov-GigaPath"))]
p2 <- ggplot(long, aes(effect_TITAN, other_effect, colour = comparison)) +
  geom_hline(yintercept = 0, colour = "grey85") +
  geom_vline(xintercept = 0, colour = "grey85") +
  geom_abline(slope = 1, intercept = 0, linetype = 2, colour = "grey45") +
  geom_point(alpha = 0.30, size = 0.8) +
  facet_grid(outcome_type ~ comparison_label, scales = "free") +
  scale_colour_manual(values = colours[c("GigaSSL", "ProvGigaPath")]) +
  labs(x = "TITAN comparison statistic\n(Q2 continuous; AUROC binary)",
       y = "Alternative representation statistic\n(Q2 continuous; AUROC binary)",
       title = "Agreement and representation-specific performance") +
  theme_minimal(base_size = 13) + theme(legend.position = "none")

patterns <- wide[, .N, by = .(outcome_type, support_pattern)]
patterns <- patterns[support_pattern != "None"]
patterns[, support_pattern := gsub("GigaSSL", "Giga-SSL", support_pattern, fixed = TRUE)]
patterns[, support_pattern := gsub("ProvGigaPath", "Prov-GigaPath", support_pattern, fixed = TRUE)]
patterns[, support_pattern := factor(support_pattern,
  levels = patterns[order(-N), unique(support_pattern)])]
p3 <- ggplot(patterns, aes(support_pattern, N, fill = outcome_type)) +
  geom_col(position = "dodge") + coord_flip() +
  scale_fill_manual(values = c(binary = "#5B4B8A", continuous = "#2A9D8F")) +
  labs(x = NULL, y = "Matched tasks",
       title = "C  Shared and representation-specific crossings", fill = NULL) +
  theme_minimal(base_size = 12) + theme(legend.position = "top")

if (!exists("robustness")) {
  message("Core comparison tables are complete; deferring grouped-retention ",
          "figures until the post-grouping summary pass.")
  quit(save = "no", status = 0L)
}

retention_counts <- robustness[, .N, by = .(
  outcome_type, primary_consensus_class, tss_retention_class
)]
retention_counts[, primary_consensus_class := factor(
  primary_consensus_class,
  levels = c("all three", "exactly two", "representation specific"),
  labels = c("3", "2", "1")
)]
retention_counts[, tss_retention_class := factor(
  tss_retention_class,
  levels = c("complete retention", "partial retention", "no retention"),
  labels = c("All primary crossings retained", "Some retained", "None retained")
)]
p4 <- ggplot(retention_counts,
             aes(primary_consensus_class, N, fill = tss_retention_class)) +
  geom_col(width = 0.72) +
  geom_text(aes(label = N), position = position_stack(vjust = 0.5),
            colour = "white", fontface = "bold", size = 3.2) +
  facet_wrap(~ outcome_type, scales = "free_y") +
  scale_fill_manual(values = c(
    "All primary crossings retained" = "#17806D",
    "Some retained" = "#D97706", "None retained" = "#B8403E"
  )) +
  labs(
    x = "Representations crossing the primary threshold",
    y = "Union-positive tasks",
    title = "D  Retention with tissue-source-site codes held apart",
    fill = NULL
  ) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "top", axis.text.x = element_text(size = 9))

dir.create("results/figures", recursive = TRUE, showWarnings = FALSE)
dir.create("figures", recursive = TRUE, showWarnings = FALSE)
ggsave("results/figures/Figure8_foundation_model_comparison_A.png", p1,
       width = 8.2, height = 4.3, dpi = 320)
ggsave("results/figures/Figure8_foundation_model_comparison_B.png", p2,
       width = 9.2, height = 6.5, dpi = 320)
ggsave("results/figures/Figure8_foundation_model_comparison_C.png", p3,
       width = 8.2, height = 5.0, dpi = 320)
ggsave("results/figures/Figure8_foundation_model_comparison_D.png", p4,
       width = 8.2, height = 5.0, dpi = 320)
comparison_consensus_retention <- p3 | p4
ggsave("results/figures/Figure2_foundation_model_breadth_effect.png",
       p1, width = 9.2, height = 5.0, dpi = 320)
ggsave("figures/Figure2_foundation_model_breadth_effect.png",
       p1, width = 9.2, height = 5.0, dpi = 320,
       bg = "white")
ggsave("results/figures/FigureS12_paired_representation_effects.png",
       p2, width = 10.2, height = 7.0, dpi = 320, bg = "white")
ggsave("figures/FigureS12_paired_representation_effects.png",
       p2, width = 10.2, height = 7.0, dpi = 320, bg = "white")
ggsave("results/figures/Figure3_foundation_model_consensus_retention.png",
       comparison_consensus_retention, width = 11.6, height = 5.6, dpi = 320)
ggsave("figures/Figure3_foundation_model_consensus_retention.png",
       comparison_consensus_retention, width = 11.6, height = 5.6, dpi = 320,
       bg = "white")
top <- p1 | p3
bottom <- p2 | p4 + plot_layout(widths = c(1.65, 1))
combined <- top / bottom + plot_layout(heights = c(0.85, 1.25))
ggsave("results/figures/Figure8_foundation_model_comparison.png", combined,
       width = 14.5, height = 11.5, dpi = 320)
ggsave("figures/Figure8_foundation_model_comparison.png", combined,
       width = 14.5, height = 11.5, dpi = 320, bg = "white")
print(summary)
print(pairwise)
