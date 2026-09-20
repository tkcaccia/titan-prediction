.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(msigdbr)
})

columns <- c(
  "gs_name", "gene_symbol", "ncbi_gene", "gs_collection",
  "gs_subcollection", "db_version", "gs_id", "gs_description"
)
hallmarks <- msigdbr(species = "Homo sapiens", collection = "H")
reactome <- msigdbr(
  species = "Homo sapiens", collection = "C2", subcollection = "CP:REACTOME"
)
ontology <- msigdbr(
  species = "Homo sapiens", collection = "C5", subcollection = "GO:BP"
)
gene_sets <- rbind(
  hallmarks[, columns],
  reactome[
    reactome$gs_name == "REACTOME_GLUTATHIONE_SYNTHESIS_AND_RECYCLING",
    columns
  ],
  ontology[
    ontology$gs_name == "GOBP_VITAMIN_B6_METABOLIC_PROCESS",
    columns
  ]
)
if (length(unique(gene_sets$gs_name)) != 52L) {
  stop("Expected 50 Hallmarks plus two focused metabolic pathways")
}
versions <- unique(gene_sets$db_version)
if (length(versions) != 1L) stop("Mixed MSigDB versions are not allowed")

stem <- file.path(
  "data", "reference", paste0("pathway_gene_sets_msigdbr_", versions)
)
saveRDS(gene_sets, paste0(stem, ".rds"), compress = "xz")
fwrite(gene_sets, paste0(stem, ".csv"))
message("Saved 52 pathway definitions from MSigDB ", versions)
