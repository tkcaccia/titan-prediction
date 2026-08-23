suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(patchwork)
  library(TITANPred)
})
source("R/utils.R")
cfg <- load_project_config()

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

# Select a clinically comparable pair rather than the globally most extreme
# pair. Eligibility requires a non-empty TITAN slide report describing a male
# patient with sigmoid-colon, moderately differentiated, pT3 adenocarcinoma and
# clear resection margins. Each case must have at most two of ten continuous
# predictions outside the 1st-99th reference-percentile interval. Within
# same-site/same-sex groups satisfying those constraints, choose the pair with
# the greatest complete-profile separation. This is a deployment illustration,
# not an additional validation analysis.
continuous <- as.data.table(coad_predictions)[outcome_type == "continuous"]
profile <- dcast(continuous, patient_id ~ endpoint, value.var = "reference_percentile")
profile_ids <- profile$patient_id
profile_matrix <- as.matrix(profile[, -"patient_id"])
reports <- fread(cfg$paths$slide_reports)
first_recorded <- function(x) {
  x <- as.character(x[!is.na(x) & nzchar(as.character(x))])
  if (length(x)) x[1L] else NA_character_
}
report_candidates <- reports[
  project_id == "TCGA-COAD" & !is.na(slide_reports) & nzchar(slide_reports),
  .(
    site = first_recorded(site_of_resection_or_biopsy),
    sex = first_recorded(sex),
    report_text = paste(unique(slide_reports), collapse = " ")
  ),
  by = .(patient_id = submitter_id)
]
report_candidates[, report_lower := tolower(report_text)]
report_candidates[, pathology_eligible :=
  grepl("moderately[ -]differentiated", report_lower) &
  grepl("pt3", report_lower) &
  grepl("sigmoid", report_lower) &
  grepl("r0|margin.{0,35}(negative|tumor-free|uninvolved)", report_lower)
]
report_candidates[, profile_row := match(patient_id, profile_ids)]
report_candidates <- report_candidates[pathology_eligible & !is.na(profile_row)]
report_candidates[, saturated_endpoints := rowSums(
  profile_matrix[profile_row, , drop = FALSE] <= 1 |
    profile_matrix[profile_row, , drop = FALSE] >= 99
)]
report_candidates <- report_candidates[saturated_endpoints <= 2]

pair_candidates <- rbindlist(lapply(
  split(report_candidates, paste(report_candidates$site, report_candidates$sex)),
  function(g) {
    if (nrow(g) < 2L) return(NULL)
    cmb <- combn(seq_len(nrow(g)), 2L)
    data.table(
      id1 = g$patient_id[cmb[1L, ]], id2 = g$patient_id[cmb[2L, ]],
      site = g$site[cmb[1L, ]], sex = g$sex[cmb[1L, ]],
      saturated1 = g$saturated_endpoints[cmb[1L, ]],
      saturated2 = g$saturated_endpoints[cmb[2L, ]],
      distance = vapply(seq_len(ncol(cmb)), function(j) {
        sqrt(sum((
          profile_matrix[g$profile_row[cmb[1L, j]], ] -
            profile_matrix[g$profile_row[cmb[2L, j]], ]
        )^2))
      }, numeric(1))
    )
  }
))
if (!nrow(pair_candidates)) stop("No clinically comparable COAD example pair was eligible.")
setorder(pair_candidates, -distance, id1, id2)
selected_ids <- unlist(pair_candidates[1L, .(id1, id2)], use.names = FALSE)

# Example A is oriented toward the higher mean MSI/immune/mutation-context
# percentile; this orientation is for readable labelling only.
orientation_endpoints <- c(
  "MANTIS score", "MSIsensor score", "Lymphocyte Infiltration Signature Score",
  "TIL Regional Fraction", "Nonsilent Mutation Rate", "SNV Neoantigens",
  "Silent Mutation Rate"
)
orientation <- continuous[
  patient_id %chin% selected_ids & endpoint %chin% orientation_endpoints,
  .(orientation_score = mean(reference_percentile)), by = patient_id
]
selected_ids <- orientation[order(-orientation_score), patient_id]
writeLines(selected_ids, "results/predictions/coad_example_patients.txt")

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
example_map[, `:=`(
  profile_distance = pair_candidates$distance[1L],
  selection_rule = paste(
    "same reported sex and sigmoid site; moderately differentiated pT3",
    "adenocarcinoma with clear margins; no more than two saturated continuous",
    "reference percentiles per case; maximum distance within eligible pairs"
  ),
  shared_features = paste(
    "Both cases were men with sigmoid-colon, moderately differentiated (G2),",
    "pT3 adenocarcinoma and tumour-free resection margins."
  )
)]

clinical_context <- data.table(
  patient_id = c("TCGA-AA-A01F", "TCGA-AA-3972"),
  pathology = c(
    paste(
      "The sigmoid resection contained an ulcerated grade-2 adenocarcinoma",
      "that had crossed the muscular wall into pericolic fat (pT3). Both",
      "resection ends were free of carcinoma; lymphatic invasion was recorded,",
      "and 2 of 30 regional nodes contained metastasis (pN1)."
    ),
    paste(
      "The sigmoid colectomy contained an ulcerated grade-2 colorectal",
      "adenocarcinoma extending through the bowel wall into adjacent mesocolic",
      "fat (pT3). The proximal and distal resection margins were uninvolved;",
      "the supplied slide summary did not state a nodal category."
    )
  ),
  treatment = c(
    paste(
      "NCI GDC records list fluorouracil, leucovorin calcium and oxaliplatin",
      "from day 62 to day 215, each with the recorded outcome 'Complete",
      "Response'. Follow-up disease status was 'with tumor' on day 31 and",
      "'unknown' on day 974; the recorded vital status was alive."
    ),
    paste(
      "NCI GDC records list capecitabine and oxaliplatin beginning on day 60,",
      "with the recorded outcome 'Progressive Disease'; recurrence was recorded",
      "on day 1216. Later records list fluorouracil, leucovorin, oxaliplatin and",
      "bevacizumab through day 1369, also with progressive disease. Follow-up",
      "on day 1551 was 'with tumor'; the recorded vital status was alive."
    )
  ),
  source = paste(
    "Pathology was paraphrased from TCGA-Slide-Reports.csv distributed with",
    "the TITAN study (Ding et al., Nature Medicine 2025;",
    "doi:10.1038/s41591-025-03982-3). Treatment and follow-up fields were",
    "retrieved from the public NCI GDC Cases API",
    "(https://api.gdc.cancer.gov/cases) on 16 August 2026."
  )
)
example_map <- merge(example_map, clinical_context, by = "patient_id",
                     all.x = TRUE, sort = FALSE)
example_map[, example_rank := match(example, c("COAD example A", "COAD example B"))]
setorder(example_map, example_rank)
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
    clinical_context = as.list(example_map[i, .(
      shared_features, pathology, treatment, source
    )]),
    quiet = TRUE
  )
}

navy <- "#17324D"
teal <- "#00A7A5"
coral <- "#F05D5E"
muted <- "#64748B"
sample_palette <- c("COAD example A" = teal, "COAD example B" = coral)

radar_a <- as.data.frame(selected[
  example == "COAD example A" & outcome_type == "continuous"
])
radar_b <- as.data.frame(selected[
  example == "COAD example B" & outcome_type == "continuous"
])
p_radar_a <- plot_titan_radar(radar_a) +
  labs(
    title = paste0("A  Example A - ", unique(radar_a$patient_id)),
    subtitle = "All 10 continuous predictions; exact values at radar corners"
  )
p_radar_b <- plot_titan_radar(radar_b) +
  labs(
    title = paste0("B  Example B - ", unique(radar_b$patient_id)),
    subtitle = "All 10 continuous predictions; exact values at radar corners"
  )

binary <- selected[outcome_type == "binary"]
binary[, endpoint_label := fcase(
  endpoint == "MSI-H strict (MANTIS >0.6)", "MSI-H strict (>0.6)",
  endpoint == "MSI-H (MANTIS >0.4)", "MSI-H (>0.4)",
  family == "driver_mutation", paste(endpoint, "mutation"),
  family == "oncogenic_pathway", paste(endpoint, "pathway"),
  default = endpoint
)]
binary[, endpoint_label := paste0(
  endpoint_label, "  (n=", training_n, "; +", training_positive,
  "/-", training_negative, ")"
)]
binary[, endpoint_label := factor(endpoint_label,
                                  levels = rev(unique(endpoint_label[order(reference_rank)])))]
p_binary <- ggplot(binary, aes(reference_rank, endpoint_label, color = example)) +
  geom_vline(xintercept = 50, color = "#9DAABD", linewidth = 0.45, linetype = 2) +
  geom_line(aes(group = endpoint_label), color = "#D7DEE8", linewidth = 0.9) +
  geom_point(aes(shape = predicted_class), size = 3.1, stroke = 1,
             position = position_dodge(width = 0.45)) +
  scale_color_manual(values = sample_palette) +
  scale_shape_manual(values = c("0" = 1, "1" = 19),
                     labels = c("0" = "Negative call", "1" = "Positive call")) +
  scale_x_continuous(limits = c(0, 100), breaks = seq(0, 100, 25),
                     labels = function(x) paste0(x, "%")) +
  labs(
    title = "C  Binary calls for the same clinically comparable cases",
    subtitle = "TCGA out-of-fold LDA-score rank; filled points are positive calls, not probabilities",
    x = "TCGA out-of-fold score rank (not probability)", y = NULL,
    color = NULL, shape = NULL
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

figure <- ((p_radar_a | p_radar_b) / p_binary +
             plot_layout(heights = c(1.35, 1))) +
  plot_annotation(
    title = "TITANPred converts one COAD feature vector into a multi-endpoint molecular profile",
    subtitle = paste(
      "Both examples are male, sigmoid-colon, grade-2 pT3 adenocarcinomas with",
      "clear margins; the pair was selected after limiting profile saturation."
    ),
    caption = paste0(
      "Example A: ", example_map[example == "COAD example A", patient_id],
      "; example B: ", example_map[example == "COAD example B", patient_id],
      ". Corner labels show TCGA reference percentile | original prediction. ",
      "Binary ranks describe uncalibrated scores and are not probabilities. ",
      "These full-cohort-fit examples are not validation evidence."
    ),
    theme = theme(
      plot.title = element_text(face = "bold", size = 17, color = navy),
      plot.subtitle = element_text(size = 10, color = muted),
      plot.caption = element_text(size = 8.3, color = muted, hjust = 0)
    )
  )

ggsave("figures/Figure7_COAD_TITANPred_examples.png", figure,
       width = 13.2, height = 11.2, dpi = 320, bg = "white")
ggsave("figures/Figure7_COAD_TITANPred_examples.pdf", figure,
       width = 13.2, height = 11.2, device = cairo_pdf, bg = "white")

cat("Selected:", paste(example_map$patient_id, collapse = " and "), "\n")
cat("Reports:", paste(list.files("results/reports", pattern = "COAD_example", full.names = TRUE), collapse = "\n"), "\n")
