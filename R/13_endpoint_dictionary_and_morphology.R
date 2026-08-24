.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(ggrepel)
})
source("R/utils.R")
cfg <- load_project_config()

dir.create("results/tables", recursive = TRUE, showWarnings = FALSE)
dir.create("figures", recursive = TRUE, showWarnings = FALSE)

# -----------------------------------------------------------------------------
# Endpoint provenance dictionary
# -----------------------------------------------------------------------------
continuous <- fread("results/tables/continuous_screen.csv")
binary <- fread("results/tables/binary_screen.csv")
cohort <- readRDS("data/processed/patient_cohort.rds")
cohort_counts <- as.data.table(cohort$meta)[, .(
  embedding_cohort_patients = .N
), by = tumor_type]

continuous_tests <- continuous[, .(
  outcome_type = "continuous", family, subfamily, tumor_type, endpoint,
  source, analysed_patients = n, positive = NA_integer_, negative = NA_integer_
)]
binary_tests <- binary[, .(
  outcome_type = "binary", family, subfamily, tumor_type, endpoint,
  source, analysed_patients = n, positive, negative
)]
tests <- rbindlist(list(continuous_tests, binary_tests), use.names = TRUE)
tests <- merge(tests, cohort_counts, by = "tumor_type", all.x = TRUE)
tests[, `:=`(
  missing_patients = embedding_cohort_patients - analysed_patients,
  missing_percent = 100 *
    (embedding_cohort_patients - analysed_patients) /
    embedding_cohort_patients
)]

expression_signatures <- c(
  "Proliferation", "Wound Healing", "Macrophage Regulation",
  "Lymphocyte Infiltration Signature Score", "IFN-gamma Response",
  "TGF-beta Response", "CTA Score", "Th1 Cells", "Th2 Cells", "Th17 Cells"
)
cibersort_fractions <- c(
  "B Cells Memory", "B Cells Naive", "Dendritic Cells Activated",
  "Dendritic Cells Resting", "Eosinophils", "Macrophages M0",
  "Macrophages M1", "Macrophages M2", "Mast Cells Activated",
  "Mast Cells Resting", "Monocytes", "Neutrophils",
  "NK Cells Activated", "NK Cells Resting", "Plasma Cells",
  "T Cells CD4 Memory Activated", "T Cells CD4 Memory Resting",
  "T Cells CD4 Naive", "T Cells CD8", "T Cells Follicular Helper",
  "T Cells gamma delta", "T Cells Regulatory Tregs"
)
repertoire_features <- c(
  "BCR Evenness", "BCR Shannon", "BCR Richness",
  "TCR Evenness", "TCR Shannon", "TCR Richness"
)
genomic_context_features <- c(
  "Number of Segments", "Fraction Altered", "Aneuploidy Score",
  "Homologous Recombination Defects"
)
mutation_burden_features <- c("Silent Mutation Rate", "Nonsilent Mutation Rate")
neoantigen_features <- c("SNV Neoantigens", "Indel Neoantigens")

definition_for <- function(outcome_type, family, endpoint) {
  transform <- continuous_endpoint_transform(family, endpoint)
  transform_text <- if (transform == "log1p") {
    "Natural log of one plus the source value before modelling"
  } else {
    "None; source value used as supplied"
  }

  if (family == "driver_mutation") return(list(
    definition_group = "Gene-specific somatic mutation",
    measurement_class = "directly observed genomic alteration",
    source_modality = "Tumour DNA sequencing (MC3 consensus somatic calls)",
    direct_vs_inferred = "Sequence-supported alteration call; computationally called",
    derivation_algorithm = paste(
      "MC3 consensus PASS call restricted to nine protein-altering variant",
      "classes; wild type requires a matched primary-tumour MC3 profile"
    ),
    original_scale = "Binary 0/1 per gene",
    transformation = "None",
    expected_measurement_error = paste(
      "Affected by tumour purity, coverage, variant allele fraction and caller",
      "consensus; no technical-replicate error estimate was supplied"
    ),
    biological_interpretation = paste(
      "Presence of at least one qualifying protein-altering", endpoint,
      "variant; not every allele is a functionally validated driver"
    ),
    equivalence_caveat = paste(
      "Research sequencing call, not a clinically certified companion-diagnostic",
      "assay"
    ),
    source_reference = "MC3; Bailey et al. 2018 (10.1016/j.cell.2018.02.060)",
    same_histology_modality = FALSE
  ))

  if (family == "oncogenic_pathway") return(list(
    definition_group = "Oncogenic-pathway alteration",
    measurement_class = "composite genomic-context score",
    source_modality = "Integrated somatic mutation and copy-number alteration data",
    direct_vs_inferred = "Derived binary pathway composite",
    derivation_algorithm = paste(
      "Sanchez-Vega pathway-level matrix; a patient is positive when a source-defined",
      "member gene is altered; any altered primary aliquot defines positivity"
    ),
    original_scale = "Binary 0/1 pathway status",
    transformation = "None",
    expected_measurement_error = paste(
      "Inherits platform, calling and pathway-membership uncertainty; different",
      "member alterations are collapsed into one label"
    ),
    biological_interpretation = paste(endpoint, "pathway alteration status"),
    equivalence_caveat = "Composite research label, not a single directly measured assay",
    source_reference = "Sanchez-Vega et al. 2018 (10.1016/j.cell.2018.03.035)",
    same_histology_modality = FALSE
  ))

  if (family == "aneuploidy" && endpoint == "Genome doubling") return(list(
    definition_group = "Genome-doubling call",
    measurement_class = "composite genomic-context score",
    source_modality = "Allele-specific copy-number profiles",
    direct_vs_inferred = "Computationally inferred whole-genome-doubling status",
    derivation_algorithm = paste(
      "Taylor et al. genome-doubling call from allele-specific copy-number/ploidy",
      "analysis; any positive primary aliquot defines patient positivity"
    ),
    original_scale = "Binary 0/1",
    transformation = "None",
    expected_measurement_error = paste(
      "Sensitive to purity, ploidy and copy-number segmentation; no technical-replicate",
      "error estimate was supplied"
    ),
    biological_interpretation = "Evidence of at least one whole-genome-doubling event",
    equivalence_caveat = "Research copy-number inference, not a directly observed karyotype",
    source_reference = "Taylor et al. 2018 (10.1016/j.ccell.2018.03.007)",
    same_histology_modality = FALSE
  ))

  if (family == "aneuploidy") return(list(
    definition_group = "Arm-level aneuploidy burden",
    measurement_class = "sequencing-derived continuous burden",
    source_modality = "Allele-specific copy-number profiles",
    direct_vs_inferred = "Computationally derived burden",
    derivation_algorithm = paste(
      "Taylor et al. arm-level gain/loss scoring; continuous values are averaged",
      "across finite primary aliquots"
    ),
    original_scale = if (endpoint == "Aneuploidy score")
      "Non-negative total arm-event score" else "Non-negative arm count",
    transformation = transform_text,
    expected_measurement_error = paste(
      "Sensitive to purity, ploidy, segmentation and arm-event thresholds; no",
      "technical-replicate error estimate was supplied"
    ),
    biological_interpretation = paste(endpoint, "as a genome-wide copy-number burden"),
    equivalence_caveat = "Research computational burden, not a directly measured cell count",
    source_reference = "Taylor et al. 2018 (10.1016/j.ccell.2018.03.007)",
    same_histology_modality = FALSE
  ))

  if (family == "fusion" && endpoint == "Fusion burden") return(list(
    definition_group = "Fusion burden",
    measurement_class = "sequencing-derived continuous burden",
    source_modality = "Tumour RNA sequencing",
    direct_vs_inferred = "Computational fusion calls collapsed to a count",
    derivation_algorithm = paste(
      "Number of unique Gao et al. final-call-set fusions among covered samples;",
      "zero requires inclusion in the study sample list and no retained call"
    ),
    original_scale = "Non-negative unique-fusion count",
    transformation = transform_text,
    expected_measurement_error = paste(
      "Affected by RNA quality, expression, caller/filter sensitivity and coverage;",
      "no technical-replicate error estimate was supplied"
    ),
    biological_interpretation = "Number of retained expressed gene-fusion events",
    equivalence_caveat = "Research RNA-seq call burden, not a targeted clinical fusion assay",
    source_reference = "Gao et al. 2018 (10.1016/j.celrep.2018.03.050)",
    same_histology_modality = FALSE
  ))

  if (family == "fusion") return(list(
    definition_group = if (grepl("^Fusion pair:", endpoint))
      "Recurrent fusion-pair call" else "Any fusion call",
    measurement_class = "directly observed genomic alteration",
    source_modality = "Tumour RNA sequencing",
    direct_vs_inferred = "Sequence-supported alteration call; computationally called",
    derivation_algorithm = paste(
      "Gao et al. final fusion call set; negatives are assigned only within the",
      "published study sample list"
    ),
    original_scale = "Binary 0/1",
    transformation = "None",
    expected_measurement_error = paste(
      "Affected by RNA quality, expression and fusion-caller/filter sensitivity;",
      "no technical-replicate error estimate was supplied"
    ),
    biological_interpretation = if (grepl("^Fusion pair:", endpoint))
      paste("Presence of", sub("^Fusion pair: ", "", endpoint)) else
      "Presence of at least one retained expressed gene fusion",
    equivalence_caveat = "Research RNA-seq call, not a targeted clinical fusion assay",
    source_reference = "Gao et al. 2018 (10.1016/j.celrep.2018.03.050)",
    same_histology_modality = FALSE
  ))

  if (family %chin% c(
    "microsatellite_instability", "microsatellite_instability_sensitivity"
  )) {
    binary_status <- outcome_type == "binary"
    return(list(
      definition_group = if (binary_status) "MSI threshold status" else "MSI score",
      measurement_class = if (binary_status)
        "composite genomic-context score" else "sequencing-derived continuous burden",
      source_modality = "Matched tumour-normal DNA sequencing",
      direct_vs_inferred = "Computational MSI score/status",
      derivation_algorithm = if (grepl("MSIsensor", endpoint))
        "MSIsensor repeat-instability score supplied by the TCGA PanCancer study"
      else if (grepl("strict", endpoint, ignore.case = TRUE))
        "MANTIS score >0.6 is MSI-H; <0.4 is stable; 0.4–0.6 is excluded"
      else if (binary_status)
        "Bonneville-aligned definition: MANTIS score >0.4 is MSI-H"
      else
        "MANTIS repeat-instability score supplied by the TCGA PanCancer study",
      original_scale = if (binary_status) "Binary 0/1" else
        "Non-negative algorithm score on its source scale",
      transformation = transform_text,
      expected_measurement_error = paste(
        "Depends on normal matching, read depth, microsatellite coverage and algorithm",
        "thresholds; no technical-replicate error estimate was supplied"
      ),
      biological_interpretation = if (binary_status)
        "Algorithm-defined MSI-high status" else paste(endpoint, "as evidence of repeat instability"),
      equivalence_caveat = paste(
        "Research sequencing algorithm output; not equivalent to a certified PCR,",
        "IHC or clinical NGS MSI assay"
      ),
      source_reference = "Bonneville et al. 2017 (10.1200/PO.17.00073); cBioPortal TCGA PanCancer",
      same_histology_modality = FALSE
    ))
  }

  if (family == "thorsson" && endpoint == "Leukocyte Fraction") return(list(
    definition_group = "Methylation-derived leukocyte fraction",
    measurement_class = "computationally inferred immune-cell fraction",
    source_modality = "Bulk-tumour DNA methylation array",
    direct_vs_inferred = "Computationally inferred",
    derivation_algorithm = "PanCancer methylation mixture estimate of total leukocyte fraction",
    original_scale = "Proportion, approximately 0–1",
    transformation = transform_text,
    expected_measurement_error = paste(
      "Mixture estimate affected by tumour purity and methylation-reference mismatch;",
      "not a direct cell count"
    ),
    biological_interpretation = "Estimated leukocyte proportion in the bulk tumour specimen",
    equivalence_caveat = "Not equivalent to flow cytometry, IHC or a directly counted immune-cell assay",
    source_reference = "Thorsson et al. 2018 (10.1016/j.immuni.2018.03.023)",
    same_histology_modality = FALSE
  ))

  if (family == "thorsson" && endpoint == "Stromal Fraction") return(list(
    definition_group = "Purity-derived stromal fraction",
    measurement_class = "composite genomic-context score",
    source_modality = "Integrated copy-number/variant purity estimate",
    direct_vs_inferred = "Computationally inferred",
    derivation_algorithm = "One minus ABSOLUTE-estimated tumour purity in the PanCancer resource",
    original_scale = "Proportion, approximately 0–1",
    transformation = transform_text,
    expected_measurement_error = paste(
      "Inherits ABSOLUTE purity, ploidy and copy-number model error; may include",
      "immune and non-immune non-tumour cells"
    ),
    biological_interpretation = "Estimated non-tumour cellular fraction",
    equivalence_caveat = "Not a direct histological stromal-area or stromal-cell count",
    source_reference = "Thorsson et al. 2018; Hoadley et al. 2018 PanCancer resource",
    same_histology_modality = FALSE
  ))

  if (family == "thorsson" && endpoint == "Intratumor Heterogeneity") return(list(
    definition_group = "Intratumour-heterogeneity score",
    measurement_class = "composite genomic-context score",
    source_modality = "Somatic variant/copy-number profiles",
    direct_vs_inferred = "Computationally inferred",
    derivation_algorithm = "ABSOLUTE-derived subclonal heterogeneity measure compiled by Thorsson et al.",
    original_scale = "Source heterogeneity score",
    transformation = transform_text,
    expected_measurement_error = paste(
      "Depends on purity, depth, copy-number state and subclonal reconstruction;",
      "no technical-replicate error estimate was supplied"
    ),
    biological_interpretation = "Estimated within-sample subclonal genomic heterogeneity",
    equivalence_caveat = "Not a direct spatial or single-cell heterogeneity measurement",
    source_reference = "Thorsson et al. 2018 (10.1016/j.immuni.2018.03.023)",
    same_histology_modality = FALSE
  ))

  if (family == "thorsson" && endpoint == "TIL Regional Fraction") return(list(
    definition_group = "H&E-derived TIL regional fraction",
    measurement_class = "pathology-associated quantity",
    source_modality = "Digitised H&E whole-slide image",
    direct_vs_inferred = "Computationally inferred from histology",
    derivation_algorithm = paste(
      "Saltz et al. deep-learning TIL map; fraction of tissue 50×50-µm regions",
      "classified as TIL-positive"
    ),
    original_scale = "Percentage of analysed tissue regions",
    transformation = transform_text,
    expected_measurement_error = paste(
      "Affected by tissue/ROI selection, image quality, classifier error and spatial",
      "sampling; no pathologist adjudication was performed here"
    ),
    biological_interpretation = "Spatial fraction of H&E regions predicted to contain lymphocytes",
    equivalence_caveat = paste(
      "Same-modality concordance target: predicting it from TITAN H&E representations",
      "is not cross-modal molecular prediction or a directly counted TIL assay"
    ),
    source_reference = "Saltz et al. 2018 (10.1016/j.celrep.2018.03.086); Thorsson et al. 2018",
    same_histology_modality = TRUE
  ))

  if (family == "thorsson" && endpoint %chin% cibersort_fractions) return(list(
    definition_group = "CIBERSORT immune-cell fraction",
    measurement_class = "computationally inferred immune-cell fraction",
    source_modality = "Bulk-tumour RNA sequencing",
    direct_vs_inferred = "Computationally inferred",
    derivation_algorithm = paste(
      "CIBERSORT deconvolution with the LM22 leukocyte signature; relative fraction",
      "within the inferred leukocyte compartment"
    ),
    original_scale = "Relative proportion, approximately 0–1",
    transformation = transform_text,
    expected_measurement_error = paste(
      "Reference-signature and collinearity error, RNA quality and tumour-mixture",
      "dependence; relative fractions are compositional"
    ),
    biological_interpretation = paste("Inferred relative abundance of", endpoint),
    equivalence_caveat = "Not equivalent to flow cytometry, IHC or a direct cell count",
    source_reference = "Newman et al. 2015 (10.1038/nmeth.3337); Thorsson et al. 2018",
    same_histology_modality = FALSE
  ))

  if (family == "thorsson" && endpoint %chin% expression_signatures) return(list(
    definition_group = "RNA-expression signature",
    measurement_class = "transcriptomic signature",
    source_modality = "Bulk-tumour RNA sequencing",
    direct_vs_inferred = "Derived gene-set score",
    derivation_algorithm = paste(
      "Published PanImmune gene-expression signature scoring on bulk RNA-seq;",
      "gene set and scoring definition follow Thorsson et al."
    ),
    original_scale = "Source signature score; not a physical unit",
    transformation = transform_text,
    expected_measurement_error = paste(
      "Affected by RNA quality, library normalisation, tumour composition, gene-set",
      "choice and batch; no technical-replicate error estimate was supplied"
    ),
    biological_interpretation = paste(endpoint, "transcriptional programme score"),
    equivalence_caveat = "Not a directly measured protein, immune-cell count or certified biomarker",
    source_reference = "Thorsson et al. 2018 (10.1016/j.immuni.2018.03.023)",
    same_histology_modality = FALSE
  ))

  if (family == "thorsson" && endpoint %chin% repertoire_features) return(list(
    definition_group = "Immune-repertoire diversity",
    measurement_class = "sequencing-derived continuous burden",
    source_modality = "Unselected bulk-tumour RNA sequencing",
    direct_vs_inferred = "Computationally reconstructed repertoire metric",
    derivation_algorithm = paste(
      "BCR/TCR CDR3 reconstruction from RNA-seq followed by richness, Shannon or",
      "evenness calculation as supplied by Thorsson et al."
    ),
    original_scale = if (grepl("Evenness", endpoint)) "Index, approximately 0–1" else
      if (grepl("Richness", endpoint)) "Non-negative reconstructed-clonotype count" else
        "Non-negative Shannon diversity index",
    transformation = transform_text,
    expected_measurement_error = paste(
      "Strongly dependent on RNA sequencing depth and abundance; unselected RNA-seq",
      "recovers only a subset of the repertoire"
    ),
    biological_interpretation = paste(endpoint, "of the reconstructed intratumour repertoire"),
    equivalence_caveat = "Not equivalent to targeted BCR/TCR sequencing or direct lymphocyte counts",
    source_reference = "Thorsson et al. 2018 (10.1016/j.immuni.2018.03.023)",
    same_histology_modality = FALSE
  ))

  if (family == "thorsson" && endpoint %chin% neoantigen_features) return(list(
    definition_group = "Predicted neoantigen burden",
    measurement_class = "sequencing-derived continuous burden",
    source_modality = "Somatic variants, HLA calls and tumour RNA sequencing",
    direct_vs_inferred = "In-silico peptide–MHC prediction",
    derivation_algorithm = "Thorsson PanImmune neoantigen prediction workflow for SNVs or indels",
    original_scale = "Non-negative predicted-neoantigen count",
    transformation = transform_text,
    expected_measurement_error = paste(
      "Inherits variant, HLA and expression-call error plus peptide-binding model",
      "uncertainty; predicted binding is not immunogenicity"
    ),
    biological_interpretation = paste(endpoint, "predicted from tumour molecular data"),
    equivalence_caveat = "Not a directly measured T-cell response or validated neoantigen assay",
    source_reference = "Thorsson et al. 2018 (10.1016/j.immuni.2018.03.023)",
    same_histology_modality = FALSE
  ))

  if (family == "thorsson" && endpoint %chin% mutation_burden_features) return(list(
    definition_group = "Somatic mutation rate",
    measurement_class = "sequencing-derived continuous burden",
    source_modality = "Tumour DNA sequencing",
    direct_vs_inferred = "Derived mutation-rate burden",
    derivation_algorithm = "PanCancer silent or nonsilent somatic mutation rate compiled by Thorsson et al.",
    original_scale = "Non-negative source mutation rate",
    transformation = transform_text,
    expected_measurement_error = paste(
      "Depends on tumour purity, sequencing coverage, callable territory and somatic",
      "variant calling"
    ),
    biological_interpretation = paste(endpoint, "as a genome-wide mutation burden"),
    equivalence_caveat = "Research burden estimate, not a platform-harmonised clinical TMB assay",
    source_reference = "Thorsson et al. 2018; TCGA MC3",
    same_histology_modality = FALSE
  ))

  if (family == "thorsson" && endpoint %chin% genomic_context_features) return(list(
    definition_group = "Genomic-context score",
    measurement_class = "composite genomic-context score",
    source_modality = "Somatic copy-number and/or variant profiles",
    direct_vs_inferred = "Computationally derived",
    derivation_algorithm = paste(
      "PanCancer genomic-context feature compiled by Thorsson et al.; exact source",
      "definition is retained in the PanImmune feature matrix"
    ),
    original_scale = if (endpoint == "Fraction Altered") "Proportion, approximately 0–1" else
      "Non-negative source score/count",
    transformation = transform_text,
    expected_measurement_error = paste(
      "Inherits purity, coverage, segmentation and source-algorithm uncertainty;",
      "no technical-replicate error estimate was supplied"
    ),
    biological_interpretation = paste(endpoint, "as a tumour genomic-context feature"),
    equivalence_caveat = "Research computational score, not a direct laboratory measurement",
    source_reference = "Thorsson et al. 2018 (10.1016/j.immuni.2018.03.023)",
    same_histology_modality = FALSE
  ))

  stop("No endpoint provenance definition for ", outcome_type, "/", family,
       "/", endpoint)
}

definitions <- unique(tests[, .(outcome_type, family, endpoint, source)])
definition_rows <- lapply(seq_len(nrow(definitions)), function(i) {
  key <- definitions[i]
  cbind(key, as.data.table(definition_for(
    key$outcome_type, key$family, key$endpoint
  )))
})
definition_dictionary <- rbindlist(definition_rows, use.names = TRUE, fill = TRUE)
setorder(definition_dictionary, measurement_class, family, endpoint)
fwrite(
  definition_dictionary,
  "results/tables/endpoint_definition_dictionary.csv"
)

endpoint_dictionary <- merge(
  tests, definition_dictionary,
  by = c("outcome_type", "family", "endpoint", "source"), all.x = TRUE
)
endpoint_dictionary[, target_id := paste(
  outcome_type, family, tumor_type, endpoint, sep = "::"
)]
setcolorder(endpoint_dictionary, c(
  "target_id", "outcome_type", "family", "subfamily", "tumor_type",
  "endpoint", "source", "measurement_class", "source_modality",
  "direct_vs_inferred", "derivation_algorithm", "original_scale",
  "transformation", "analysed_patients", "positive", "negative",
  "embedding_cohort_patients", "missing_patients", "missing_percent",
  "expected_measurement_error", "biological_interpretation",
  "equivalence_caveat", "same_histology_modality", "source_reference",
  "definition_group"
))
setorder(endpoint_dictionary, outcome_type, family, tumor_type, endpoint)
stopifnot(nrow(endpoint_dictionary) == nrow(continuous) + nrow(binary))
fwrite(endpoint_dictionary, "results/tables/endpoint_dictionary.csv")

endpoint_summary <- endpoint_dictionary[, .(
  cancer_endpoint_tests = .N,
  unique_endpoint_definitions = uniqueN(paste(outcome_type, family, endpoint)),
  median_missing_percent = median(missing_percent),
  minimum_missing_percent = min(missing_percent),
  maximum_missing_percent = max(missing_percent),
  same_histology_modality_tests = sum(same_histology_modality)
), by = .(measurement_class, direct_vs_inferred)]
setorder(endpoint_summary, measurement_class, direct_vs_inferred)
fwrite(endpoint_summary, "results/tables/endpoint_dictionary_summary.csv")

# -----------------------------------------------------------------------------
# Qualitative morphology context through within-cancer nearest-neighbour
# retrieval. This is deliberately not labelled as mechanistic attribution:
# only global 768-dimensional representations and TITAN-generated slide reports
# are available, not patch embeddings, attention maps or blinded review.
# -----------------------------------------------------------------------------
continuous_predictions <- fread(
  "results/predictions/continuous_repeated_oof_predictions.csv.gz"
)[, .(
  observed = first(observed), predicted_value = mean(predicted)
), by = .(family, tumor_type, endpoint, patient)]
binary_predictions <- fread(
  "results/predictions/binary_repeated_oof_predictions.csv.gz"
)[, .(
  observed = first(observed), predicted_class = as.integer(mean(predicted) >= 0.5),
  predicted_value = mean(lda_score)
), by = .(family, tumor_type, endpoint, patient)]

reports <- fread(cfg$paths$slide_reports)
reports[, `:=`(
  patient = substr(submitter_id, 1, 12),
  slide_normalized = tolower(sub("\\.svs$", "", slide_id)),
  report_text = gsub("[[:space:]]+", " ", trimws(slide_reports))
)]
report_patients <- unique(reports$patient)

context_models <- data.table(
  outcome_type = c("continuous", "continuous", "continuous", "continuous", "binary"),
  family = c("thorsson", "thorsson", "thorsson", "aneuploidy", "driver_mutation"),
  tumor_type = c("BLCA", "TGCT", "BRCA", "UCEC", "THYM"),
  endpoint = c(
    "TIL Regional Fraction", "Macrophages M2", "Wound Healing",
    "Aneuploidy score", "GTF2I"
  ),
  context_class = c(
    "H&E-derived pathology quantity", "RNA-derived CIBERSORT fraction",
    "RNA-expression signature", "copy-number-derived burden",
    "sequence-supported mutation call"
  )
)
context_models[, model_index := .I]

report_patterns <- c(
  "lymphoid/inflammatory infiltrate" =
    "lymphoepithelioma|lymphocytic|lymphoid|inflammatory|inflammation|plasma cell",
  "necrosis" = "necros",
  "desmoplastic/stromal" = "desmoplas|stromal|stroma|fibro",
  "papillary" = "papillar",
  "glandular/tubular" = "gland|tubul|cribriform|acinar",
  "solid/sheet-like" = "solid|sheet-like|sheets of",
  "squamous/keratinising" = "squamous|keratin",
  "mucinous" = "mucin",
  "spindle/pleomorphic" = "spindle|pleomorph",
  "high-grade/poorly differentiated" = "high-grade|poorly differentiated|grade 3|grade 4",
  "low-grade/well differentiated" = "low-grade|well differentiated|grade 1"
)

extract_report_terms <- function(text) {
  hits <- names(report_patterns)[vapply(
    report_patterns, function(pattern) grepl(pattern, text, ignore.case = TRUE),
    logical(1)
  )]
  if (length(hits)) paste(hits, collapse = "; ") else
    "none of the prespecified report terms"
}

cosine_similarity <- function(a, b) {
  drop(b %*% a) / (sqrt(rowSums(b^2)) * sqrt(sum(a^2)))
}

select_anchor <- function(d, stratum, require_immune_context = FALSE) {
  d <- copy(d)
  d[, `:=`(
    observed_rank = frank(observed, ties.method = "average") / .N,
    predicted_rank = frank(predicted_value, ties.method = "average") / .N,
    report_available = patient %chin% report_patients
  )]
  d[, rank_discrepancy := abs(predicted_rank - observed_rank)]
  if (stratum == "high") {
    z <- d[report_available & predicted_rank >= 0.90 & observed_rank >= 0.75]
    if (require_immune_context) {
      immune_patients <- reports[grepl(
        report_patterns[["lymphoid/inflammatory infiltrate"]],
        report_text, ignore.case = TRUE
      ), unique(patient)]
      z <- z[patient %chin% immune_patients]
    }
    setorder(z, -predicted_rank, rank_discrepancy)
  } else {
    z <- d[report_available & predicted_rank <= 0.10 & observed_rank <= 0.25]
    if (require_immune_context) {
      immune_patients <- reports[grepl(
        report_patterns[["lymphoid/inflammatory infiltrate"]],
        report_text, ignore.case = TRUE
      ), unique(patient)]
      z <- z[!patient %chin% immune_patients]
    }
    setorder(z, predicted_rank, rank_discrepancy)
  }
  if (!nrow(z)) stop("No morphology anchor for ", stratum)
  z[1]
}

select_binary_anchor <- function(d, stratum) {
  d <- copy(d)
  d[, report_available := patient %chin% report_patients]
  if (stratum == "high") {
    z <- d[report_available & observed == 1 & predicted_class == 1]
    setorder(z, -predicted_value)
  } else {
    z <- d[report_available & observed == 0 & predicted_class == 0]
    setorder(z, predicted_value)
  }
  if (!nrow(z)) stop("No binary morphology anchor for ", stratum)
  z[1]
}

prediction_sets <- list()
context_rows <- list()

for (i in seq_len(nrow(context_models))) {
  model <- context_models[i]
  if (model$outcome_type == "continuous") {
    d <- continuous_predictions[
      family == model$family & tumor_type == model$tumor_type &
        endpoint == model$endpoint
    ]
    d[, `:=`(
      observed_rank = frank(observed, ties.method = "average") / .N,
      predicted_rank = frank(predicted_value, ties.method = "average") / .N,
      predicted_class = NA_integer_
    )]
  } else {
    d <- binary_predictions[
      family == model$family & tumor_type == model$tumor_type &
        endpoint == model$endpoint
    ]
    d[, `:=`(
      observed_rank = fifelse(observed == 1, 0.90, 0.10),
      predicted_rank = frank(predicted_value, ties.method = "average") / .N
    )]
  }
  if (!nrow(d)) stop("Missing context model predictions: ", model$endpoint)
  d[, model_index := i]
  prediction_sets[[i]] <- d

  for (stratum in c("high", "low")) {
    anchor <- if (model$outcome_type == "continuous") {
      select_anchor(
        d, stratum,
        require_immune_context = identical(model$endpoint, "TIL Regional Fraction")
      )
    } else {
      select_binary_anchor(d, stratum)
    }

    if (model$outcome_type == "continuous") {
      candidates <- d[
        patient != anchor$patient & patient %chin% report_patients
      ]
      candidates <- if (stratum == "high") {
        candidates[predicted_rank >= 0.75]
      } else {
        candidates[predicted_rank <= 0.25]
      }
    } else {
      candidates <- d[
        patient != anchor$patient & patient %chin% report_patients &
          observed == anchor$observed & predicted_class == anchor$predicted_class
      ]
    }
    anchor_vector <- cohort$X[anchor$patient, ]
    candidate_vectors <- cohort$X[candidates$patient, , drop = FALSE]
    candidates[, embedding_cosine_similarity := cosine_similarity(
      anchor_vector, candidate_vectors
    )]
    setorder(candidates, -embedding_cosine_similarity)
    neighbour <- candidates[1]

    for (role in c("anchor", "nearest neighbour")) {
      row <- if (role == "anchor") anchor else neighbour
      context_rows[[length(context_rows) + 1L]] <- data.table(
        model_index = i, outcome_type = model$outcome_type,
        family = model$family, tumor_type = model$tumor_type,
        endpoint = model$endpoint, context_class = model$context_class,
        stratum = stratum, role = role, patient = row$patient,
        observed = row$observed, predicted_value = row$predicted_value,
        predicted_class = row$predicted_class,
        observed_rank = row$observed_rank,
        predicted_rank = row$predicted_rank,
        embedding_cosine_similarity_to_anchor = if (role == "anchor")
          1 else row$embedding_cosine_similarity,
        anchor_patient = anchor$patient
      )
    }
  }
}

context <- rbindlist(context_rows, use.names = TRUE, fill = TRUE)

# Select a report-covered slide nearest the patient mean representation. This
# keeps multiple-slide patients patient-level while giving the qualitative
# report audit one deterministic slide identifier.
slide_features <- fread(
  cfg$paths$titan_features,
  select = c("filename", cohort$feature_names)
)
feature_names <- cohort$feature_names
slide_features[, `:=`(
  patient = substr(filename, 1, 12),
  slide_normalized = tolower(filename)
)]
slide_features <- slide_features[patient %chin% unique(context$patient)]

select_representative_slide <- function(patient_id) {
  z <- slide_features[patient == patient_id]
  report_slides <- reports[patient == patient_id, unique(slide_normalized)]
  if (any(z$slide_normalized %chin% report_slides)) {
    z <- z[slide_normalized %chin% report_slides]
  }
  x <- as.matrix(z[, ..feature_names])
  centre <- cohort$X[patient_id, ]
  z$distance_to_patient_mean <- rowSums((x -
    matrix(centre, nrow(x), length(centre), byrow = TRUE))^2)
  z[which.min(distance_to_patient_mean), .(
    representative_slide = filename,
    slide_normalized,
    distance_to_patient_mean
  )]
}

representative_slides <- rbindlist(lapply(
  unique(context$patient), function(patient) cbind(
    data.table(patient = patient), select_representative_slide(patient)
  )
))
context <- merge(context, representative_slides, by = "patient", all.x = TRUE)
context <- merge(
  context,
  reports[, .(slide_normalized, report_text, site_of_resection_or_biopsy)],
  by = "slide_normalized", all.x = TRUE
)
context[, `:=`(
  report_terms = vapply(report_text, extract_report_terms, character(1)),
  report_excerpt = substr(report_text, 1, 360),
  patient_slides = cohort$meta$n_slides[match(patient, cohort$meta$patient)],
  report_provenance = paste(
    "TITAN-generated slide report from the same WSI; not an independent",
    "pathologist annotation"
  ),
  interpretability_limit = paste(
    "Nearest-neighbour context is qualitative. Global pooled embeddings do not",
    "localise causal patches or establish a morphological mechanism."
  )
)]
context[, `:=`(
  stratum_order = match(stratum, c("high", "low")),
  role_order = match(role, c("anchor", "nearest neighbour"))
)]
setorder(context, model_index, stratum_order, role_order)
context[, c("stratum_order", "role_order") := NULL]
fwrite(context, "results/tables/morphology_context_examples.csv")

morphology_summary <- context[role == "anchor", .(
  high_anchor = patient[stratum == "high"],
  low_anchor = patient[stratum == "low"],
  high_slide = representative_slide[stratum == "high"],
  low_slide = representative_slide[stratum == "low"],
  high_observed = observed[stratum == "high"],
  low_observed = observed[stratum == "low"],
  high_prediction = predicted_value[stratum == "high"],
  low_prediction = predicted_value[stratum == "low"],
  high_report_terms = report_terms[stratum == "high"],
  low_report_terms = report_terms[stratum == "low"]
), by = .(model_index, outcome_type, family, tumor_type, endpoint, context_class)]
morphology_summary[, interpretation := fifelse(
  endpoint == "TIL Regional Fraction",
  paste(
    "Same-modality concordance/positive-control example because the target was",
    "itself inferred from H&E; not molecular prediction"
  ),
  paste(
    "Qualitative embedding-neighbour and generated-report context only; no",
    "patch attribution or blinded pathologist review"
  )
)]
fwrite(
  morphology_summary,
  "results/tables/morphology_context_model_summary.csv"
)

# Figure S4: all held-out patients are shown; selected anchors and their nearest
# within-cancer embedding neighbours are overlaid. Morphology terms are kept in
# the table to avoid unreadable annotation and false mechanistic emphasis.
plot_data <- rbindlist(prediction_sets, fill = TRUE)
plot_data <- merge(
  plot_data, context_models[, .(model_index, context_class)],
  by = "model_index", all.x = TRUE
)
plot_data[, model_label := paste0(
  tumor_type, " — ", endpoint, "\n", context_class
)]
selected_plot <- merge(
  context[, .(
    model_index, patient, stratum, role, embedding_cosine_similarity_to_anchor
  )],
  unique(plot_data[, .(
    model_index, patient, model_label, observed_rank, predicted_rank
  )]), by = c("model_index", "patient"), all.x = TRUE
)
selected_plot[, point_label := fifelse(
  role == "anchor", fifelse(stratum == "high", "H", "L"),
  fifelse(stratum == "high", "HN", "LN")
)]

segments <- dcast(
  selected_plot,
  model_index + model_label + stratum ~ role,
  value.var = c("observed_rank", "predicted_rank")
)

navy <- "#17324D"
ink <- "#253746"
muted <- "#64748B"
p <- ggplot(plot_data, aes(observed_rank, predicted_rank)) +
  geom_point(color = "#C8D1DA", alpha = 0.55, size = 1.3) +
  geom_segment(
    data = segments,
    aes(
      x = `observed_rank_anchor`, y = `predicted_rank_anchor`,
      xend = `observed_rank_nearest neighbour`,
      yend = `predicted_rank_nearest neighbour`, color = stratum
    ), inherit.aes = FALSE, linewidth = 0.8, alpha = 0.7
  ) +
  geom_point(
    data = selected_plot,
    aes(color = stratum, shape = role), size = 3.2, stroke = 1.1
  ) +
  geom_text_repel(
    data = selected_plot[role == "anchor"],
    aes(label = point_label, color = stratum),
    min.segment.length = 0, box.padding = 0.25, point.padding = 0.2,
    seed = 20260824, fontface = "bold", size = 3.4, show.legend = FALSE
  ) +
  facet_wrap(~model_label, ncol = 3) +
  scale_color_manual(values = c(high = "#D95F43", low = "#3274A1")) +
  scale_shape_manual(values = c(anchor = 19, `nearest neighbour` = 17)) +
  coord_cartesian(xlim = c(0, 1), ylim = c(0, 1)) +
  labs(
    title = "High- and low-prediction anchors with within-cancer TITAN neighbours",
    subtitle = paste(
      "H/L: selected anchor; HN/LN: closest patient-level mean-embedding neighbour.",
      "Ranks are based on repeated out-of-fold predictions."
    ),
    x = "Observed endpoint rank (binary model: class at 0.1/0.9)",
    y = "Mean repeated out-of-fold prediction rank",
    color = "Prediction stratum", shape = "Example role",
    caption = paste(
      "Nearest-neighbour retrieval is qualitative and not patch-level attribution.",
      "TITAN-generated report context and exact slide IDs are in Table S14."
    )
  ) +
  theme_minimal(base_size = 10, base_family = "Arial") +
  theme(
    text = element_text(color = ink), panel.grid.minor = element_blank(),
    panel.grid.major = element_line(color = "#E5EAF0", linewidth = 0.3),
    strip.text = element_text(face = "bold", color = navy, size = 9),
    plot.title = element_text(face = "bold", color = navy, size = 15),
    plot.subtitle = element_text(color = muted),
    plot.caption = element_text(color = muted, hjust = 0),
    legend.position = "bottom"
  )
ggsave(
  "figures/FigureS4_morphology_context.png", p,
  width = 12.0, height = 7.6, dpi = 320, bg = "white"
)

message(
  "Endpoint dictionary: ", nrow(endpoint_dictionary), " modelled targets; ",
  nrow(definition_dictionary), " unique endpoint definitions. Morphology context: ",
  nrow(context), " anchor/neighbour rows across ", nrow(context_models), " models."
)
