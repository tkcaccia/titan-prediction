suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
})
dir.create("figures", recursive = TRUE, showWarnings = FALSE)

theme_titan <- function(base_size = 10) {
  theme_minimal(base_size = base_size) +
    theme(
      panel.grid.minor = element_blank(), panel.grid.major.y = element_blank(),
      plot.title = element_text(face = "bold", size = rel(1.25)),
      plot.subtitle = element_text(color = "#405065"),
      strip.text = element_text(face = "bold"),
      legend.position = "bottom"
    )
}

family_labels <- c(
  thorsson = "Immune / genomic context",
  aneuploidy = "Aneuploidy",
  fusion = "Fusion",
  microsatellite_instability = "MSI",
  microsatellite_instability_sensitivity = "MSI (strict)",
  oncogenic_pathway = "Oncogenic pathway",
  driver_mutation = "Cancer-gene mutation"
)

# Figure 1: patient-first workflow.
png("figures/Figure1_patient_first_workflow.png", width = 2400, height = 1250,
    res = 220, bg = "white")
par(mar = c(0, 0, 0, 0), xpd = NA)
plot.new(); plot.window(xlim = c(0, 15), ylim = c(0, 8))
box <- function(x, y, w, h, title, body, fill) {
  rect(x, y, x + w, y + h, col = fill, border = "#203040", lwd = 1.5)
  text(x + 0.18, y + h - 0.35, title, adj = c(0, 1), font = 2, cex = 0.95)
  text(x + 0.18, y + h - 0.85, body, adj = c(0, 1), cex = 0.72)
}
arrow <- function(x0, y0, x1, y1) arrows(x0, y0, x1, y1, length = 0.08,
                                           lwd = 1.5, col = "#405065")
box(0.4, 4.7, 3.2, 2.1, "11,449 diagnostic slides",
    "Frozen 768-dimensional\nTITAN feature vectors", "#E8F1FF")
box(4.2, 4.7, 3.2, 2.1, "9,404 independent patients",
    "Mean pool every eligible slide\n843 patients have >1 slide", "#EAF8F2")
box(8.0, 4.7, 3.0, 2.1, "32 cancer-specific cohorts",
    "Never pool cancer types\nPatient is the CV unit", "#FFF5E5")
box(11.6, 5.5, 2.9, 1.4, "Continuous targets",
    "PLS1 regression\nQ-squared", "#F3EAFE")
box(11.6, 3.6, 2.9, 1.4, "Binary targets",
    "PLS scores + LDA\nBalanced accuracy", "#FDECEF")
box(3.1, 1.0, 4.0, 1.7, "Nested validation for both routes",
    "5 x 5 CV; training-only selection\nup to 99 label permutations", "#EEF2F5")
box(7.9, 1.0, 4.0, 1.7, "Robustness and deployment",
    "Repeated CV; site-grouped folds\nfirst-slide sensitivity; saved models", "#EEF2F5")
arrow(3.6, 5.75, 4.2, 5.75); arrow(7.4, 5.75, 8.0, 5.75)
arrow(11.0, 5.85, 11.6, 6.1); arrow(11.0, 5.45, 11.6, 4.3)
arrow(9.2, 4.7, 7.1, 2.35)
arrow(7.1, 1.85, 7.9, 1.85)
text(0.4, 7.55, "Patient-level TITAN prediction atlas", adj = c(0, 0.5),
     font = 2, cex = 1.45, col = "#172B4D")
dev.off()

continuous <- fread("results/tables/continuous_screen.csv")
binary <- fread("results/tables/binary_screen.csv")
continuous[, family_label := family_labels[family]]
binary[, family_label := family_labels[family]]

# Figure 2: strongest supported continuous results, with tested endpoint/cancer
# combinations shown explicitly and genomic-context outcomes distinguished.
cs <- continuous[tier %in% c("A", "B")]
top_keys <- cs[order(-q2), head(.SD, 10L), by = family][,
  .(family, tumor_type, endpoint)]
cp <- merge(continuous, top_keys, by = c("family", "tumor_type", "endpoint"))
cp[, label := paste(endpoint, tumor_type, family_label, sep = " | ")]
cp[, label := factor(label, levels = rev(unique(label[order(q2)])))]
p2 <- ggplot(cp, aes(q2, label, color = family_label, shape = tier)) +
  geom_vline(xintercept = c(0.20, 0.40), linetype = c(2, 3), color = "#94A3B8") +
  geom_point(size = 2.5, alpha = 0.9) +
  scale_shape_manual(values = c(A = 19, B = 17, C = 1)) +
  labs(
    title = "Strongest cancer-specific continuous predictions by family",
    subtitle = "Patient-level out-of-fold Q-squared; Tier A >=0.40, Tier B >=0.20 with FDR <5%",
    x = expression("Out-of-fold " * Q^2), y = NULL, color = NULL, shape = "Tier"
  ) + theme_titan(9)
ggsave("figures/Figure2_continuous_atlas.png", p2, width = 9.2, height = 8.5,
       dpi = 300, bg = "white")

# Figure 3: strongest supported binary molecular results.
bs <- binary[tier %in% c("A", "B")]
bp <- bs[order(-adjusted_balanced_accuracy), head(.SD, 10L), by = family]
bp[, label := paste(endpoint, tumor_type, family_label, sep = " | ")]
bp[, label := factor(label, levels = rev(unique(label)))]
p3 <- ggplot(bp, aes(balanced_accuracy, label, color = family_label, shape = tier)) +
  geom_vline(xintercept = c(0.60, 0.70), linetype = c(2, 3), color = "#94A3B8") +
  geom_point(aes(size = positive), alpha = 0.9) +
  scale_shape_manual(values = c(A = 19, B = 17)) +
  scale_size_continuous(range = c(1.8, 5), breaks = c(50, 150, 300)) +
  labs(
    title = "Strongest cancer-specific binary molecular predictions by family",
    subtitle = "PLS latent scores with LDA; point size is the number of positive patients",
    x = "Out-of-fold balanced accuracy", y = NULL, color = NULL,
    shape = "Tier", size = "Positive patients"
  ) +
  guides(color = guide_legend(nrow = 2), shape = guide_legend(nrow = 1),
         size = guide_legend(nrow = 1)) +
  theme_titan(9)
ggsave("figures/Figure3_binary_atlas.png", p3, width = 10.5, height = 11,
       dpi = 300, bg = "white")

# Figure 4: breadth of supported predictions by cancer and target family.
counts <- rbindlist(list(
  cs[, .N, by = .(tumor_type, family_label, tier)],
  bs[, .N, by = .(tumor_type, family_label, tier)]
), fill = TRUE)
counts[, tumor_type := factor(tumor_type,
  levels = counts[, .(total = sum(N)), by = tumor_type][order(total), tumor_type])]
p4 <- ggplot(counts, aes(N, tumor_type, fill = family_label, alpha = tier)) +
  geom_col() +
  scale_alpha_manual(values = c(A = 1, B = 0.55)) +
  labs(
    title = "Supported prediction targets differ across cancer types",
    subtitle = "Counts include Tier A and Tier B endpoints after within-cancer family FDR control",
    x = "Number of supported cancer-endpoint pairs", y = NULL,
    fill = NULL, alpha = "Tier"
  ) + theme_titan(9)
ggsave("figures/Figure4_supported_counts.png", p4, width = 10.5, height = 8.3,
       dpi = 300, bg = "white")

# Figure 5: collection-site grouped sensitivity.
site_c <- fread("results/tables/continuous_site_grouped_sensitivity.csv")
site_b <- fread("results/tables/binary_site_grouped_sensitivity.csv")
site <- rbindlist(list(
  site_c[feasible == TRUE, .(
    family, tumor_type, endpoint, random = random_q2,
    grouped = site_grouped_q2, metric = "Q-squared"
  )],
  site_b[feasible == TRUE, .(
    family, tumor_type, endpoint, random = random_balanced_accuracy,
    grouped = site_grouped_balanced_accuracy, metric = "Balanced accuracy"
  )]
), fill = TRUE)
site[, family_label := family_labels[family]]
p5 <- ggplot(site, aes(random, grouped, color = family_label)) +
  geom_abline(slope = 1, intercept = 0, color = "#64748B", linetype = 2) +
  geom_point(alpha = 0.75, size = 2) +
  facet_wrap(~metric, scales = "free") +
  labs(
    title = "Collection-site separation tests internal robustness",
    subtitle = "Points below the diagonal attenuate when tissue-source sites cannot cross folds",
    x = "Random-fold performance", y = "Site-grouped performance", color = NULL
  ) + theme_titan(10)
ggsave("figures/Figure5_site_grouped_sensitivity.png", p5, width = 10, height = 5.4,
       dpi = 300, bg = "white")

# Figure 6: secondary PLS1-versus-PLS2 comparison for inflammatory blocks.
pc <- fread("results/tables/pls1_vs_pls2_inflammation.csv")
pcancer <- fread("results/tables/pls1_vs_pls2_inflammation_by_cancer.csv")
block_labels <- c(
  infiltration_signatures = "Infiltration / signatures",
  immune_repertoire = "Immune repertoire",
  inferred_cell_fractions = "Inferred cell fractions"
)
pc[, block_label := block_labels[block]]
pcancer[, block_label := block_labels[block]]
p6a <- ggplot(pc, aes(pls1, pls2, color = block_label)) +
  geom_abline(slope = 1, intercept = 0, linetype = 2, color = "#64748B") +
  geom_point(alpha = 0.35, size = 1.2) +
  coord_equal() +
  labs(title = "a  Matched target performance", x = expression("PLS1 " * Q^2),
       y = expression("PLS2 " * Q^2), color = NULL) + theme_titan(9)
p6b <- ggplot(pcancer, aes(mean_delta, reorder(tumor_type, mean_delta), color = block_label)) +
  geom_vline(xintercept = 0, linetype = 2, color = "#64748B") +
  geom_point(size = 2) +
  labs(title = "b  Mean change within cancer", x = expression(Delta * Q^2 * " (PLS2 - PLS1)"),
       y = NULL, color = NULL) + theme_titan(9)
ggsave("figures/Figure6a_pls1_vs_pls2_targets.png", p6a, width = 6.2, height = 5.5,
       dpi = 300, bg = "white")
ggsave("figures/Figure6b_pls1_vs_pls2_cancers.png", p6b, width = 7.5, height = 7.5,
       dpi = 300, bg = "white")
