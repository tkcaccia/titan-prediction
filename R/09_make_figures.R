suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(grid)
})
source("R/utils.R")
dir.create("figures", recursive = TRUE, showWarnings = FALSE)

navy <- "#17324D"
ink <- "#253746"
muted <- "#64748B"
teal <- "#12A594"
coral <- "#E76F51"
gold <- "#E9A23B"
blue <- "#3A78C2"
purple <- "#7C5CC4"
green <- "#5A9B62"

family_labels <- c(
  thorsson = "Immune / genomic context",
  aneuploidy = "Aneuploidy",
  fusion = "Fusion",
  microsatellite_instability = "MSI",
  microsatellite_instability_sensitivity = "MSI (strict sensitivity)",
  oncogenic_pathway = "Oncogenic pathway",
  driver_mutation = "Cancer-gene mutation"
)
family_palette <- c(
  "Immune / genomic context" = teal,
  "Aneuploidy" = gold,
  "Fusion" = purple,
  "MSI" = blue,
  "MSI (strict sensitivity)" = "#6B9FD4",
  "Oncogenic pathway" = green,
  "Cancer-gene mutation" = coral
)

theme_titan <- function(base_size = 10) {
  theme_minimal(base_size = base_size, base_family = "Arial") +
    theme(
      text = element_text(color = ink),
      panel.grid.minor = element_blank(),
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_line(color = "#E6EBF0", linewidth = 0.35),
      plot.title = element_text(face = "bold", size = rel(1.22), color = navy),
      plot.subtitle = element_text(color = muted, margin = margin(b = 8)),
      plot.caption = element_text(color = muted, hjust = 0, size = rel(0.82)),
      axis.title = element_text(face = "bold"),
      legend.position = "bottom",
      legend.title = element_text(face = "bold"),
      plot.margin = margin(12, 18, 12, 12)
    )
}

continuous <- fread("results/tables/continuous_screen.csv")
binary <- fread("results/tables/binary_screen.csv")
continuous[, family_label := family_labels[family]]
binary[, family_label := family_labels[family]]
continuous[, evidence_band := factor(
  fifelse(tier == "A", "Higher effect", fifelse(tier == "B", "Moderate effect",
                                                  "Screen-negative")),
  levels = c("Higher effect", "Moderate effect", "Screen-negative")
)]
binary[, evidence_band := factor(
  fifelse(tier == "A", "Higher effect", fifelse(tier == "B", "Moderate effect",
                                                  "Screen-negative")),
  levels = c("Higher effect", "Moderate effect", "Screen-negative")
)]
  continuous[, global_status := factor(
  fifelse(q_value_global < 0.05, "Passes across-cancer sensitivity",
          "Within-cancer only"),
  levels = c("Passes across-cancer sensitivity", "Within-cancer only")
)]
binary[, global_status := factor(
  fifelse(q_value_global < 0.05, "Passes across-cancer sensitivity",
          "Within-cancer only"),
  levels = c("Passes across-cancer sensitivity", "Within-cancer only")
)]

# Figure 1: a publication-quality, patient-first study map.
cohort <- readRDS("data/processed/patient_cohort.rds")
n_slides <- sum(cohort$meta$n_slides)
n_patients <- nrow(cohort$meta)
n_multi <- sum(cohort$meta$n_slides > 1L)
n_cancers <- uniqueN(na.omit(cohort$meta$tumor_type))

png("figures/Figure1_patient_first_workflow.png", width = 3000, height = 1600,
    res = 260, bg = "white")
grid.newpage()
grid.text("From diagnostic slides to a patient-level TCGA benchmark",
          x = unit(0.04, "npc"), y = unit(0.94, "npc"), just = "left",
          gp = gpar(fontfamily = "Arial", fontsize = 24, fontface = "bold",
                    col = navy))
grid.text("Fixed pretrained TITAN representations; cancer-specific downstream models; no external cohort",
          x = unit(0.04, "npc"), y = unit(0.895, "npc"), just = "left",
          gp = gpar(fontfamily = "Arial", fontsize = 12, col = muted))

card <- function(x, y, w, h, number, title, body, fill, accent) {
  grid.roundrect(x = unit(x, "npc"), y = unit(y, "npc"),
                 width = unit(w, "npc"), height = unit(h, "npc"),
                 r = unit(5, "mm"),
                 gp = gpar(fill = fill, col = "#D9E2EA", lwd = 1.2))
  grid.circle(x = unit(x - w/2 + 0.035, "npc"),
              y = unit(y + h/2 - 0.045, "npc"), r = unit(5.2, "mm"),
              gp = gpar(fill = accent, col = NA))
  grid.text(number, x = unit(x - w/2 + 0.035, "npc"),
            y = unit(y + h/2 - 0.045, "npc"),
            gp = gpar(fontfamily = "Arial", fontsize = 12,
                      fontface = "bold", col = "white"))
  grid.text(title, x = unit(x - w/2 + 0.07, "npc"),
            y = unit(y + h/2 - 0.04, "npc"), just = "left",
            gp = gpar(fontfamily = "Arial", fontsize = 14,
                      fontface = "bold", col = navy))
  grid.text(body, x = unit(x - w/2 + 0.025, "npc"),
            y = unit(y + h/2 - 0.10, "npc"), just = c("left", "top"),
            gp = gpar(fontfamily = "Arial", fontsize = 10.5, col = ink,
                      lineheight = 1.2))
}
connector <- function(x0, y0, x1, y1) {
  grid.lines(x = unit(c(x0, x1), "npc"), y = unit(c(y0, y1), "npc"),
             arrow = arrow(length = unit(3.2, "mm"), type = "closed"),
             gp = gpar(col = "#9AA9B7", lwd = 2))
}

card(0.16, 0.68, 0.25, 0.27, "1",
     paste(format(n_slides, big.mark = ","), "eligible slides"),
     "Primary-tumour diagnostic WSIs\n768 TITAN dimensions per slide\nExact slide-report provenance audited",
     "#F4F8FC", blue)
card(0.50, 0.68, 0.25, 0.27, "2",
     paste(format(n_patients, big.mark = ","), "patients"),
     paste0("Mean pool all eligible slides\n",
            format(n_multi, big.mark = ","),
            " patients have multiple slides\nNo patient crosses validation folds"),
     "#F1FAF8", teal)
card(0.84, 0.68, 0.25, 0.27, "3", sprintf("%d cancer cohorts", n_cancers),
     "Models fitted within each cancer\nMissing molecular profiles remain missing\nWild type requires assay coverage",
     "#FFF8ED", gold)
connector(0.295, 0.68, 0.365, 0.68)
connector(0.635, 0.68, 0.705, 0.68)

card(0.29, 0.31, 0.37, 0.25, "4A", "Continuous endpoints",
     "PLS1 regression\nHeld-out Q2, RMSE and Spearman correlation\nImmune, genomic and instability endpoints",
     "#F4F1FB", purple)
card(0.71, 0.31, 0.37, 0.25, "4B", "Binary endpoints",
     "PLS latent scores with LDA\nSensitivity, specificity, balanced accuracy and AUROC\nMutations, pathways, MSI, fusions and aneuploidy",
     "#FFF2EF", coral)
connector(0.50, 0.535, 0.34, 0.445)
connector(0.50, 0.535, 0.66, 0.445)

grid.roundrect(x = unit(0.50, "npc"), y = unit(0.095, "npc"),
               width = unit(0.88, "npc"), height = unit(0.12, "npc"),
               r = unit(4, "mm"), gp = gpar(fill = navy, col = NA))
grid.text("Patient-level nested validation  |  within-cancer multiplicity control  |  site-grouped robustness",
          x = unit(0.50, "npc"), y = unit(0.112, "npc"),
          gp = gpar(fontfamily = "Arial", fontsize = 9.4, col = "white"))
grid.text("Slide-pooling sensitivity  |  research model metadata  |  no external validation",
          x = unit(0.50, "npc"), y = unit(0.075, "npc"),
          gp = gpar(fontfamily = "Arial", fontsize = 9.4, col = "white"))
dev.off()

# Figure 2: concise continuous landscape.
cs <- continuous[tier %chin% c("A", "B")][order(-q2)]
cp <- head(cs, 30L)
cp[, display := paste0(tumor_type, "  ·  ", endpoint)]
cp[, display := factor(display, levels = rev(display))]
p2 <- ggplot(cp, aes(q2, display, color = family_label)) +
  geom_segment(aes(x = 0, xend = q2, yend = display),
               color = "#DCE4EB", linewidth = 0.8) +
  geom_vline(xintercept = c(0.20, 0.40), linetype = c(2, 3),
             color = "#94A3B8") +
  geom_point(aes(shape = global_status, size = evidence_band), stroke = 1.2) +
  scale_color_manual(values = family_palette, drop = FALSE) +
  scale_shape_manual(values = c("Passes across-cancer sensitivity" = 19,
                                "Within-cancer only" = 21), drop = FALSE) +
  scale_size_manual(values = c("Higher effect" = 3.6,
                               "Moderate effect" = 2.8,
                               "Screen-negative" = 2.2), drop = FALSE) +
  labs(
    title = "Continuous signals are strong in selected cancer–endpoint pairs",
    subtitle = sprintf(
      "Top 30 within-cancer candidates; %d continuous pairs passed the stricter across-cancer family correction",
      continuous[tier %chin% c("A", "B") & q_value_global < 0.05, .N]
    ),
    x = expression("Patient-level outer-fold " * Q^2), y = NULL,
    color = "Endpoint family", shape = "Multiplicity sensitivity",
    size = "Effect band",
    caption = "Open points indicate within-cancer evidence only. Thresholds are discovery-prioritisation rules, not clinical grades."
  ) + theme_titan(9.2) +
  theme(legend.box = "vertical")
ggsave("figures/Figure2_continuous_atlas.png", p2, width = 10.2, height = 8.7,
       dpi = 320, bg = "white")

# Figure 3: concise binary landscape with endpoint family in every label.
bs <- binary[tier %chin% c("A", "B")][order(-balanced_accuracy)]
bp <- head(bs, 30L)
bp[, display := paste0(tumor_type, "  ·  ", endpoint, "  [", family_label, "]")]
bp[, display := factor(display, levels = rev(display))]
p3 <- ggplot(bp, aes(balanced_accuracy, display, color = family_label)) +
  geom_segment(aes(x = 0.5, xend = balanced_accuracy, yend = display),
               color = "#DCE4EB", linewidth = 0.8) +
  geom_vline(xintercept = c(0.60, 0.70), linetype = c(2, 3),
             color = "#94A3B8") +
  geom_point(aes(shape = global_status, size = positive), stroke = 1.2) +
  scale_color_manual(values = family_palette, drop = FALSE) +
  scale_shape_manual(values = c("Passes across-cancer sensitivity" = 19,
                                "Within-cancer only" = 21), drop = FALSE) +
  scale_size_continuous(range = c(2.4, 5.2)) +
  labs(
    title = "Binary discrimination is endpoint- and cancer-specific",
    subtitle = "Top 30 PLS–LDA candidates; filled points pass the stricter across-cancer family correction",
    x = "Patient-level outer-fold balanced accuracy", y = NULL,
    color = "Endpoint family", shape = "Multiplicity sensitivity",
    size = "Positive patients",
    caption = "Mutation and pathway labels are explicitly separated. LDA scores are not calibrated probabilities."
  ) + theme_titan(8.6) +
  theme(legend.box = "vertical")
ggsave("figures/Figure3_binary_atlas.png", p3, width = 11.2, height = 9.4,
       dpi = 320, bg = "white")

# Figure 4: observed-versus-predicted examples. Panel A deliberately shows the
# strongest primary patient-level nested-CV continuous result; panel B uses the
# strongest mean repeated-CV binary classifier.
performance <- fread("results/tables/screen_positive_performance_summary.csv")
bin_pred <- fread("results/predictions/binary_repeated_oof_predictions.csv.gz")
cont_job <- continuous[tier %chin% c("A", "B")][order(-q2)][1L]
bin_job <- performance[outcome_type == "binary"][order(-repeated_balanced_accuracy_mean)][1L]
cont_checkpoint <- file.path(
  "data/processed/checkpoints/continuous",
  paste0(safe_name(cont_job$family, cont_job$tumor_type, cont_job$endpoint), ".rds")
)
cd <- readRDS(cont_checkpoint)$predictions
bd_repeat <- bin_pred[
  family == bin_job$family & tumor_type == bin_job$tumor_type &
    endpoint == bin_job$endpoint
]
# Raw LDA scores from independently fitted repeats need not share a common
# scale. Standardize within repeat before forming a patient-level illustrative
# mean; repeat-specific AUROCs are calculated from the untransformed scores.
bd_repeat[, lda_score_z := {
  score_sd <- sd(lda_score)
  if (!is.finite(score_sd) || score_sd == 0) {
    rep(0, .N)
  } else {
    (lda_score - mean(lda_score)) / score_sd
  }
}, by = `repeat`]
bd <- bd_repeat[, .(
  observed = observed[1L], lda_score_z = mean(lda_score_z)
), by = patient]
bd[, observed_label := factor(observed, levels = c(0L, 1L),
                              labels = c("Observed negative", "Observed positive"))]

p4a <- ggplot(cd, aes(observed, predicted)) +
  geom_abline(slope = 1, intercept = 0, linetype = 2, color = muted) +
  geom_point(color = teal, alpha = 0.55, size = 1.8) +
  geom_smooth(method = "lm", se = TRUE, color = navy, fill = "#BFD7EA",
              linewidth = 0.8) +
  labs(
    title = paste0("A  ", cont_job$tumor_type, ": ", cont_job$endpoint),
    subtitle = sprintf("Patient-level nested CV: Q2 %.2f; RMSE %.2f; Spearman %.2f",
                       cont_job$q2, cont_job$rmse, cont_job$spearman),
    x = "Observed value", y = "Held-out prediction"
  ) + theme_titan(10) + theme(legend.position = "none")

p4b <- ggplot(bd, aes(observed_label, lda_score_z, fill = observed_label)) +
  geom_violin(width = 0.8, alpha = 0.28, color = NA, trim = FALSE) +
  geom_boxplot(width = 0.22, outlier.shape = NA, alpha = 0.82, color = navy) +
  geom_jitter(position = position_jitter(width = 0.11, height = 0,
                                         seed = 20250815),
              alpha = 0.34, size = 1.2, color = ink) +
  geom_hline(yintercept = 0, linetype = 2, color = muted) +
  scale_fill_manual(values = c("Observed negative" = "#AFC9E3",
                               "Observed positive" = coral)) +
  labs(
    title = paste0("B  ", bin_job$tumor_type, ": ", bin_job$endpoint,
                   " [", family_labels[bin_job$family], "]"),
    subtitle = sprintf("Repeated nested CV: sensitivity %.2f; specificity %.2f\nbalanced accuracy %.2f; AUROC %.2f",
                       bin_job$repeated_sensitivity_mean,
                       bin_job$repeated_specificity_mean,
                       bin_job$repeated_balanced_accuracy_mean,
                       bin_job$repeated_auc_mean),
    x = NULL, y = "Mean within-repeat standardized held-out LDA score"
  ) + theme_titan(10) + theme(legend.position = "none")

png("figures/Figure4_prediction_examples.png", width = 3000, height = 1450,
    res = 300, bg = "white")
grid.newpage()
pushViewport(viewport(layout = grid.layout(1, 2, widths = unit(c(1, 1), "null"))))
print(p4a, vp = viewport(layout.pos.row = 1, layout.pos.col = 1))
print(p4b, vp = viewport(layout.pos.row = 1, layout.pos.col = 2))
dev.off()

# Figure 5: breadth of screen-positive candidates.
counts_observed <- rbindlist(list(
  continuous[tier %chin% c("A", "B"),
             .N, by = .(tumor_type, family_label)][
               , outcome_type := "Continuous"],
  binary[tier %chin% c("A", "B"),
         .N, by = .(tumor_type, family_label)][
           , outcome_type := "Binary"]
), fill = TRUE)
all_cancers <- sort(unique(c(continuous$tumor_type, binary$tumor_type)))
counts_frame <- rbindlist(list(
  CJ(tumor_type = all_cancers,
     family_label = sort(unique(na.omit(continuous$family_label))))[
       , outcome_type := "Continuous"],
  CJ(tumor_type = all_cancers,
     family_label = sort(unique(na.omit(binary$family_label))))[
       , outcome_type := "Binary"]
))
counts <- merge(
  counts_frame, counts_observed,
  by = c("tumor_type", "family_label", "outcome_type"), all.x = TRUE
)
counts[is.na(N), N := 0L]
ordering <- counts[, .(total = sum(N)), by = tumor_type][order(total), tumor_type]
counts[, tumor_type := factor(tumor_type, levels = ordering)]
p5 <- ggplot(counts, aes(N, tumor_type, fill = family_label)) +
  geom_col(width = 0.72) +
  facet_wrap(~outcome_type, scales = "free_x", nrow = 1) +
  scale_fill_manual(values = family_palette, drop = FALSE) +
  labs(
    title = "Predictability is heterogeneous across cancers",
    subtitle = "Counts use within-cancer screen criteria; absence can reflect ineligibility or a screen-negative result",
    x = "Screen-positive cancer–endpoint pairs", y = NULL,
    fill = "Endpoint family"
  ) + theme_titan(9)
ggsave("figures/Figure5_supported_counts.png", p5, width = 11.4, height = 8.1,
       dpi = 320, bg = "white")

# Figure 6: site-grouped internal sensitivity.
site_c <- fread("results/tables/continuous_site_grouped_sensitivity.csv")
site_b <- fread("results/tables/binary_site_grouped_sensitivity.csv")
site <- rbindlist(list(
  site_c[feasible == TRUE, .(
    family, random = random_q2, grouped = site_grouped_q2,
    metric = "Continuous Q²"
  )],
  site_b[feasible == TRUE, .(
    family, random = random_balanced_accuracy,
    grouped = site_grouped_balanced_accuracy,
    metric = "Binary balanced accuracy"
  )]
), fill = TRUE)
site[, family_label := family_labels[family]]
p6 <- ggplot(site, aes(random, grouped, color = family_label)) +
  geom_abline(slope = 1, intercept = 0, color = muted, linetype = 2) +
  geom_point(alpha = 0.72, size = 2.1) +
  facet_wrap(~metric, scales = "free") +
  scale_color_manual(values = family_palette, drop = FALSE) +
  labs(
    title = "Separating tissue-source sites tests internal robustness",
    subtitle = "Values below the diagonal attenuate when submitting sites cannot cross folds",
    x = "Random-fold performance", y = "Site-grouped performance",
    color = "Endpoint family",
    caption = "Site grouping remains an internal TCGA sensitivity analysis and is not external validation."
  ) + theme_titan(10)
ggsave("figures/Figure6_site_grouped_sensitivity.png", p6,
       width = 10.4, height = 5.7, dpi = 320, bg = "white")

# Supplementary PLS1-versus-PLS2 comparison.
pc <- fread("results/tables/pls1_vs_pls2_inflammation.csv")
pcancer <- fread("results/tables/pls1_vs_pls2_inflammation_by_cancer.csv")
block_labels <- c(
  infiltration_signatures = "Infiltration / signatures",
  immune_repertoire = "Immune repertoire",
  inferred_cell_fractions = "Inferred cell fractions"
)
pc[, block_label := block_labels[block]]
pcancer[, block_label := block_labels[block]]
p_s1 <- ggplot(pc, aes(pls1, pls2, color = block_label)) +
  geom_abline(slope = 1, intercept = 0, linetype = 2, color = muted) +
  geom_point(alpha = 0.35, size = 1.2) + coord_equal() +
  labs(title = "Matched response-level performance",
       x = expression("PLS1 " * Q^2), y = expression("PLS2 " * Q^2),
       color = NULL) + theme_titan(9)
p_s2 <- ggplot(pcancer,
               aes(mean_delta, reorder(tumor_type, mean_delta),
                   color = block_label)) +
  geom_vline(xintercept = 0, linetype = 2, color = muted) +
  geom_point(size = 2) +
  labs(title = "Mean change within cancer",
       x = expression(Delta * Q^2 * " (PLS2 - PLS1)"), y = NULL,
       color = NULL) + theme_titan(9)
ggsave("figures/Figure6a_pls1_vs_pls2_targets.png", p_s1,
       width = 6.2, height = 5.5, dpi = 320, bg = "white")
ggsave("figures/Figure6b_pls1_vs_pls2_cancers.png", p_s2,
       width = 7.5, height = 7.5, dpi = 320, bg = "white")
