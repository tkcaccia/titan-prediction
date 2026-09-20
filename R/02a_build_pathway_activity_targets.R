suppressPackageStartupMessages(library(data.table))
source("R/utils.R")

expression_file <- file.path(
  "data", "external", "xena",
  "EB++AdjustPANCAN_IlluminaHiSeq_RNASeqV2.geneExp.xena.gz"
)
gene_set_file <-
  "data/reference/pathway_gene_sets_msigdbr_2026.1.Hs.rds"
gene_set_csv <-
  "data/reference/pathway_gene_sets_msigdbr_2026.1.Hs.csv"
filtered_file <- file.path(
  "data", "processed", "pathway_member_expression.xena.tsv.gz"
)
assert_files(c(expression_file, gene_set_file, gene_set_csv,
               "data/processed/patient_cohort.rds"))

if (!file.exists(filtered_file) ||
    file.info(filtered_file)$mtime < file.info(gene_set_csv)$mtime ||
    file.info(filtered_file)$mtime < file.info(expression_file)$mtime) {
  python <- Sys.which("python3")
  if (!nzchar(python)) stop("python3 is required to filter the Xena matrix")
  status <- system2(python, c(
    "tools/extract_pathway_expression.py",
    "--expression", expression_file,
    "--gene-sets", gene_set_csv,
    "--output", filtered_file
  ))
  if (!identical(status, 0L)) stop("Pathway-expression extraction failed")
}

cohort <- readRDS("data/processed/patient_cohort.rds")
meta <- as.data.table(cohort$meta)[, .(patient, tumor_type)]
gene_sets <- as.data.table(readRDS(gene_set_file))
if (uniqueN(gene_sets$gs_name) != 52L) {
  stop("The pathway resource must contain 50 Hallmarks and two focused pathways")
}

expression <- fread(filtered_file, na.strings = c("NA", ""))
setnames(expression, 1L, "gene_symbol")
expression[, gene_symbol := as.character(gene_symbol)]
sample_columns <- setdiff(names(expression), "gene_symbol")
primary_columns <- sample_columns[
  nchar(sample_columns) >= 15L & substr(sample_columns, 14L, 15L) == "01"
]
patient_for_column <- substr(primary_columns, 1L, 12L)
keep_columns <- patient_for_column %chin% meta$patient
primary_columns <- primary_columns[keep_columns]
patient_for_column <- patient_for_column[keep_columns]
if (!length(primary_columns)) stop("No primary-tumour RNA samples matched the WSI cohort")

X_sample <- t(as.matrix(expression[, ..primary_columns]))
storage.mode(X_sample) <- "double"
colnames(X_sample) <- expression$gene_symbol
X_sample[!is.finite(X_sample)] <- NA_real_

# Multiple primary-tumour aliquots are averaged before a patient is scored.
patient_order <- unique(patient_for_column)
group <- match(patient_for_column, patient_order)
X_patient <- rowsum(X_sample, group, reorder = FALSE) /
  tabulate(group, nbins = length(patient_order))
rownames(X_patient) <- patient_order

pathway_members <- split(gene_sets$gene_symbol, gene_sets$gs_name)
pathway_members <- lapply(pathway_members, unique)
missing_sets <- setdiff(names(pathway_members), unique(gene_sets$gs_name))
if (length(missing_sets)) stop("Pathway definitions were lost during parsing")

score_one_cancer <- function(cancer) {
  patients <- meta[tumor_type == cancer & patient %chin% rownames(X_patient), patient]
  if (!length(patients)) return(NULL)
  X <- X_patient[patients, , drop = FALSE]
  means <- colMeans(X, na.rm = TRUE)
  sds <- apply(X, 2L, sd, na.rm = TRUE)
  informative <- is.finite(sds) & sds > 0
  Z <- sweep(X[, informative, drop = FALSE], 2L, means[informative], "-")
  Z <- sweep(Z, 2L, sds[informative], "/")

  rbindlist(lapply(names(pathway_members), function(pathway) {
    requested <- pathway_members[[pathway]]
    measured <- intersect(requested, colnames(Z))
    if (length(measured) < 2L) return(NULL)
    values <- rowMeans(Z[, measured, drop = FALSE], na.rm = TRUE)
    values[!is.finite(values)] <- NA_real_
    subfamily <- if (startsWith(pathway, "HALLMARK_")) {
      "MSigDB Hallmark"
    } else if (grepl("GLUTATHIONE", pathway)) {
      "glutathione synthesis and recycling"
    } else {
      "vitamin B6 metabolism"
    }
    data.table(
      patient = patients,
      tumor_type = cancer,
      family = "rna_pathway_activity",
      subfamily = subfamily,
      endpoint = pathway,
      outcome_type = "continuous",
      value = values,
      source = paste0(
        "UCSC_Xena_TCGA_PanCancer_RNAseq_MSigDB_",
        unique(gene_sets$db_version)
      ),
      pathway_genes_requested = length(requested),
      pathway_genes_measured = length(measured),
      score_method = paste(
        "mean of within-cancer gene-wise z scores after patient-level",
        "mean aggregation of primary-tumour RNA aliquots"
      )
    )
  }), use.names = TRUE, fill = TRUE)
}

scores <- rbindlist(lapply(unique(meta$tumor_type), score_one_cancer),
                    use.names = TRUE, fill = TRUE)
if (!nrow(scores)) stop("No pathway activity scores were constructed")
setorder(scores, tumor_type, endpoint, patient)
saveRDS(scores, "data/processed/pathway_activity_targets.rds", compress = "xz")

coverage <- scores[, .(
  patients = uniqueN(patient),
  pathway_genes_requested = unique(pathway_genes_requested),
  pathway_genes_measured = unique(pathway_genes_measured),
  mean = mean(value),
  sd = sd(value)
), by = .(tumor_type, subfamily, endpoint, source, score_method)]
fwrite(coverage, "results/tables/pathway_activity_target_audit.csv")
fwrite(data.table(
  expression_source = "UCSC Xena TCGA Pan-Cancer RNA-seq",
  expression_file = basename(expression_file),
  expression_sha256 = digest::digest(expression_file, algo = "sha256", file = TRUE),
  gene_set_source = "MSigDB",
  gene_set_version = unique(gene_sets$db_version),
  pathways = uniqueN(gene_sets$gs_name),
  hallmark_pathways = uniqueN(gene_sets[startsWith(gs_name, "HALLMARK_"), gs_name]),
  primary_rna_samples = length(primary_columns),
  matched_patients = uniqueN(patient_for_column),
  aggregation = "mean across primary-tumour RNA aliquots before scoring",
  scoring = paste(
    "mean of within-cancer gene-wise z scores; higher values indicate",
    "greater relative expression of pathway-member genes"
  )
), "results/tables/pathway_activity_source_manifest.csv")

cat("Pathway activity rows:", nrow(scores), "\n")
print(scores[, .(pathways = uniqueN(endpoint), patients = uniqueN(patient)),
             by = subfamily])
