#!/usr/bin/env Rscript

# Create a reproducible patient-overlap audit and main-manuscript Venn diagram
# from the three processed foundation-model cohorts.

models <- c(TITAN = "TITAN", `Giga-SSL` = "GigaSSL",
            `Prov-GigaPath` = "ProvGigaPath")

patient_sets <- lapply(models, function(model) {
  cohort_path <- file.path(
    "data", "processed", paste0("patient_cohort_", model, ".rds")
  )
  if (!file.exists(cohort_path)) stop("Missing cohort: ", cohort_path)
  rownames(readRDS(cohort_path)$X)
})

all_patients <- Reduce(union, patient_sets)
membership <- vapply(all_patients, function(patient) {
  paste(as.integer(vapply(patient_sets, function(x) patient %in% x,
                          logical(1))), collapse = "")
}, character(1))

region_order <- c("100", "010", "001", "110", "101", "011", "111")
region_names <- c(
  "TITAN only", "Giga-SSL only", "Prov-GigaPath only",
  "TITAN and Giga-SSL only", "TITAN and Prov-GigaPath only",
  "Giga-SSL and Prov-GigaPath only", "All three"
)
counts <- table(factor(membership, levels = region_order))

overlap <- data.frame(
  region = region_names,
  TITAN = as.integer(substr(region_order, 1, 1)),
  Giga_SSL = as.integer(substr(region_order, 2, 2)),
  Prov_GigaPath = as.integer(substr(region_order, 3, 3)),
  patients = as.integer(counts),
  percent_of_union = round(100 * as.integer(counts) / length(all_patients), 3),
  check.names = FALSE
)

dir.create(file.path("results", "tables"), recursive = TRUE,
           showWarnings = FALSE)
dir.create(file.path("results", "figures"), recursive = TRUE,
           showWarnings = FALSE)
write.csv(
  overlap,
  file.path("results", "tables", "foundation_model_patient_overlap_summary.csv"),
  row.names = FALSE,
  quote = TRUE
)

value <- setNames(overlap$patients, region_order)
expected <- c(`100` = 1L, `010` = 7L, `001` = 0L, `110` = 1070L,
              `101` = 92L, `011` = 60L, `111` = 8241L)
if (!identical(as.integer(value[names(expected)]), as.integer(expected))) {
  stop("Patient overlap has changed; inspect the processed cohorts before use.")
}

fmt <- function(x) format(x, big.mark = ",", scientific = FALSE, trim = TRUE)
cols <- c(TITAN = "#2B6CB0", `Giga-SSL` = "#D97706",
          `Prov-GigaPath` = "#17806D")
released_slides <- c(TITAN = 11449L, `Giga-SSL` = 11427L,
                     `Prov-GigaPath` = 10328L)
exact_common_slides <- 10165L
identical_slide_set_patients <- 8207L

png(
  file.path("results", "figures", "Figure1_patient_overlap_venn.png"),
  width = 2400, height = 1600, res = 300, bg = "white"
)
par(mar = c(2.0, 0.7, 1.0, 0.7), family = "sans", xpd = NA)
plot.new()
plot.window(xlim = c(0.3, 9.7), ylim = c(-0.70, 8.1), asp = 1)

text(5, 7.82, "Patient overlap across released TCGA representation datasets",
     cex = 1.48, font = 2, col = "#102A43")
text(5, 7.38,
     paste0(fmt(length(all_patients)), " patients in the union; ",
            fmt(value[["111"]]), " (",
            sprintf("%.1f", 100 * value[["111"]] / length(all_patients)),
            "%) represented in all three"),
     cex = 0.95, col = "#52667A")

centres_x <- c(4.05, 5.95, 5.00)
centres_y <- c(4.78, 4.78, 3.25)
radius <- 2.25
for (i in seq_along(centres_x)) {
  symbols(centres_x[i], centres_y[i], circles = radius, inches = FALSE,
          add = TRUE, fg = unname(cols[i]),
          bg = adjustcolor(unname(cols[i]), alpha.f = 0.17), lwd = 3)
}

text(1.25, 5.98, paste0("TITAN\n", fmt(length(patient_sets[[1]])),
                        " patients\n", fmt(released_slides[["TITAN"]]), " slides"),
     cex = 1.03, font = 2, col = cols[[1]], adj = c(0.5, 0.5))
text(8.75, 5.98,
     paste0("Giga-SSL\n", fmt(length(patient_sets[[2]])),
            " patients\n", fmt(released_slides[["Giga-SSL"]]), " slides"),
     cex = 1.03, font = 2, col = cols[[2]], adj = c(0.5, 0.5))
text(5.00, 0.40,
     paste0("Prov-GigaPath\n", fmt(length(patient_sets[[3]])),
            " patients\n", fmt(released_slides[["Prov-GigaPath"]]), " slides"),
     cex = 0.98, font = 2, col = cols[[3]], adj = c(0.5, 0.5))

region_label <- function(x, y, n, note = "", cex = 1.05, col = "#102A43") {
  text(x, y + 0.14, fmt(n), cex = cex, font = 2, col = col)
  if (nzchar(note)) text(x, y - 0.22, note, cex = 0.65, col = "#52667A")
}

region_label(2.62, 5.02, value[["100"]])
region_label(7.38, 5.02, value[["010"]])
region_label(5.00, 1.55, value[["001"]])
region_label(5.00, 5.90, value[["110"]], "TITAN + Giga-SSL", 1.00)
region_label(3.72, 3.08, value[["101"]], "TITAN +\nProv-GigaPath", 0.98)
region_label(6.28, 3.08, value[["011"]], "Giga-SSL +\nProv-GigaPath", 0.98)
region_label(5.00, 4.18, value[["111"]], "all three", 1.35, "#102A43")

text(9.55, -0.55,
     paste0("Exact common-slide intersection: ", fmt(exact_common_slides),
            " slides across ", fmt(value[["111"]]), " patients; identical slide sets for ",
            fmt(identical_slide_set_patients), " (99.6%). Region areas are schematic."),
     cex = 0.58, col = "#6B7C8F", adj = c(1, 0))
dev.off()
dir.create("figures", recursive = TRUE, showWarnings = FALSE)
file.copy(
  file.path("results", "figures", "Figure1_patient_overlap_venn.png"),
  file.path("figures", "Figure1_patient_overlap_venn.png"),
  overwrite = TRUE
)

message("Wrote patient-overlap table and Figure 1. Union n = ",
        fmt(length(all_patients)), "; all three n = ", fmt(value[["111"]]), ".")
