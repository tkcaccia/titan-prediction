suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(patchwork)
})

x <- fread("results/tables/foundation_model_matched_screen.csv")
x[, effect := fifelse(outcome_type == "continuous", q2,
                      2 * balanced_accuracy - 1)]
x[, screening_positive := fifelse(outcome_type == "continuous", q2 >= 0.20,
                                  balanced_accuracy >= 0.60)]
x[, screening_tier_A := fifelse(outcome_type == "continuous", q2 >= 0.40,
                                balanced_accuracy >= 0.70)]

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
                            "spearman", "balanced_accuracy", "auc", "pr_auc"))
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
setcolorder(pairwise, c("comparison", "outcome_type", setdiff(names(pairwise),
                                                               c("comparison", "outcome_type"))))
fwrite(pairwise, "results/tables/foundation_model_pairwise_summary.csv")

colours <- c(TITAN = "#2B6CB0", GigaSSL = "#D97706", ProvGigaPath = "#17806D")
p1 <- ggplot(summary, aes(foundation_model, screening_positive,
                          fill = foundation_model)) +
  geom_col(width = 0.68) +
  geom_text(aes(label = screening_positive), vjust = -0.3, size = 4) +
  facet_wrap(~ outcome_type, scales = "free_y") +
  scale_fill_manual(values = colours) +
  labs(x = NULL, y = "Targets meeting the prespecified\nscreening threshold",
       title = "A  Screening-positive targets on the common patient cohort") +
  theme_minimal(base_size = 12) + theme(legend.position = "none")

long <- melt(wide,
             id.vars = c("outcome_type", "family", "tumor_type", "endpoint",
                         "effect_TITAN"),
             measure.vars = c("effect_GigaSSL", "effect_ProvGigaPath"),
             variable.name = "comparison", value.name = "other_effect")
long[, comparison := sub("effect_", "", comparison)]
p2 <- ggplot(long, aes(effect_TITAN, other_effect, colour = comparison)) +
  geom_hline(yintercept = 0, colour = "grey85") +
  geom_vline(xintercept = 0, colour = "grey85") +
  geom_abline(slope = 1, intercept = 0, linetype = 2, colour = "grey45") +
  geom_point(alpha = 0.30, size = 0.8) +
  facet_grid(outcome_type ~ comparison, scales = "free") +
  scale_colour_manual(values = colours[c("GigaSSL", "ProvGigaPath")]) +
  labs(x = "TITAN effect statistic", y = "Alternative representation effect statistic",
       title = "B  Target-level held-out performance") +
  theme_minimal(base_size = 11) + theme(legend.position = "none")

patterns <- wide[, .N, by = .(outcome_type, support_pattern)]
patterns <- patterns[support_pattern != "None"]
patterns[, support_pattern := factor(support_pattern,
  levels = patterns[order(-N), unique(support_pattern)])]
p3 <- ggplot(patterns, aes(support_pattern, N, fill = outcome_type)) +
  geom_col(position = "dodge") + coord_flip() +
  scale_fill_manual(values = c(binary = "#5B4B8A", continuous = "#2A9D8F")) +
  labs(x = NULL, y = "Matched cancer-endpoint tasks",
       title = "C  Retention among screening-positive tasks", fill = NULL) +
  theme_minimal(base_size = 12) + theme(legend.position = "top")

dir.create("results/figures", recursive = TRUE, showWarnings = FALSE)
ggsave("results/figures/Figure8_foundation_model_comparison_A.png", p1,
       width = 8.2, height = 4.3, dpi = 320)
ggsave("results/figures/Figure8_foundation_model_comparison_B.png", p2,
       width = 9.2, height = 6.5, dpi = 320)
ggsave("results/figures/Figure8_foundation_model_comparison_C.png", p3,
       width = 8.2, height = 5.0, dpi = 320)
combined <- p1 / (p2 | p3) + plot_layout(heights = c(0.75, 1.25))
ggsave("results/figures/Figure8_foundation_model_comparison.png", combined,
       width = 13.5, height = 10.0, dpi = 320)
print(summary)
print(pairwise)
