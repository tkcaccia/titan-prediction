suppressPackageStartupMessages(library(data.table))

primary <- fread("results/tables/foundation_model_matched_screen.csv")
exact <- fread("results/tables/foundation_model_matched_screen_exact_common_slide.csv")
keys <- c("foundation_model", "outcome_type", "family", "subfamily",
          "tumor_type", "endpoint", "source")
metric <- function(d) fifelse(d$outcome_type == "continuous", d$q2,
                              d$auc)
positive <- function(d) fifelse(d$outcome_type == "continuous", d$q2 >= 0.20,
                                d$auc >= 0.60)
primary[, `:=`(metric_primary = metric(.SD), screen_positive_primary = positive(.SD))]
exact[, `:=`(metric_exact = metric(.SD), screen_positive_exact = positive(.SD))]
z <- merge(
  primary[, c(keys, "n", "positive", "negative", "metric_primary", "screen_positive_primary"), with = FALSE],
  exact[, c(keys, "n", "positive", "negative", "metric_exact", "screen_positive_exact"), with = FALSE],
  by = keys, suffixes = c("_primary", "_exact"), all = TRUE
)
z[, delta_exact_minus_primary := metric_exact - metric_primary]
z[, threshold_change := fcase(
  screen_positive_primary & !screen_positive_exact, "lost threshold",
  !screen_positive_primary & screen_positive_exact, "gained threshold",
  screen_positive_primary & screen_positive_exact, "retained positive",
  default = "retained negative"
)]
summary <- z[, .(
  tasks = .N,
  median_delta = median(delta_exact_minus_primary, na.rm = TRUE),
  q1_delta = quantile(delta_exact_minus_primary, 0.25, na.rm = TRUE),
  q3_delta = quantile(delta_exact_minus_primary, 0.75, na.rm = TRUE),
  spearman_primary_exact = cor(metric_primary, metric_exact, method = "spearman",
                               use = "complete.obs"),
  primary_screening_positive = sum(screen_positive_primary, na.rm = TRUE),
  exact_screening_positive = sum(screen_positive_exact, na.rm = TRUE),
  lost_threshold = sum(threshold_change == "lost threshold"),
  gained_threshold = sum(threshold_change == "gained threshold"),
  maximum_absolute_delta = max(abs(delta_exact_minus_primary), na.rm = TRUE)
), by = .(foundation_model, outcome_type)]

fwrite(z, "results/tables/foundation_model_exact_common_slide_target_sensitivity.csv")
fwrite(summary, "results/tables/foundation_model_exact_common_slide_sensitivity_summary.csv")
print(summary)
