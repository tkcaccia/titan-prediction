suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(patchwork)
})

d <- fread("results/tables/continuous_reliability_by_model.csv")
cpt <- fread("results/tables/continuous_selected_components_by_fold.csv")
d[, evidence := fifelse(n < 100, "Limited (<100)", "Standard (>=100)")]
palette <- c("Limited (<100)" = "#D95F02", "Standard (>=100)" = "#2C7FB8")

base_theme <- theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(), legend.position = "bottom",
        plot.title = element_text(face = "bold", size = 10),
        axis.title = element_text(size = 10), axis.text = element_text(size = 9))
p1 <- ggplot(d, aes(n, repeated_q2_mean, colour = evidence)) +
  geom_hline(yintercept = 0.20, linetype = 2, colour = "grey45") +
  geom_point(alpha = .75, size = 2) + geom_smooth(method = "loess", se = FALSE) +
  scale_colour_manual(values = palette) +
  labs(title = "A  Repeated Q2 by sample size", x = "Outcome-labelled patients",
       y = "Five-repeat mean Q2", colour = "Evidence category") + base_theme
p2 <- ggplot(d, aes(n, prediction_repeat_spearman_mean, colour = evidence)) +
  geom_point(alpha = .75, size = 2) + geom_smooth(method = "loess", se = FALSE) +
  scale_colour_manual(values = palette) +
  labs(title = "B  Prediction stability by sample size", x = "Outcome-labelled patients",
       y = "Mean pairwise repeat Spearman rho", colour = "Evidence category") + base_theme
small <- cpt[n < 100]
component_frequency <- small[, .(outer_fits = .N), by = selected_components]
component_frequency[, proportion := outer_fits / sum(outer_fits)]
ceiling_n <- small[selected_components == 20, .N]
ceiling_pct <- 100 * ceiling_n / nrow(small)
p3 <- ggplot(component_frequency, aes(selected_components, proportion)) +
  geom_col(fill = "#D95F02", width = .8) +
  geom_vline(xintercept = 20, linetype = 2, colour = "grey45") +
  scale_x_continuous(breaks = 1:20) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1), expand = expansion(mult = c(0, .12))) +
  annotate("text", x = 19.7, y = max(component_frequency$proportion) * 1.08,
           hjust = 1, size = 3.4,
           label = sprintf("Component 20: %d/%d outer fits (%.1f%%)",
                           ceiling_n, nrow(small), ceiling_pct)) +
  labs(title = "C  Component selections in the 91 smaller continuous models",
       subtitle = "All 25 outer fits per model are included",
       x = "Selected PLS components", y = "Proportion of outer fits") + base_theme +
  theme(legend.position = "none")

fig <- (p1 | p2) / p3 + plot_layout(heights = c(1, .85), guides = "collect")
ggsave("results/figures/FigureS5_continuous_reliability.png", fig,
       width = 10, height = 9, dpi = 320, bg = "white")
