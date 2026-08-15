# Copy to config/paths.local.R and edit only the values on the right.
paths <- list(
  titan_features = Sys.getenv("TITAN_FEATURES", "data/raw/TCGA_TITAN_features.csv"),
  slide_reports = Sys.getenv("TITAN_SLIDE_REPORTS", "data/raw/TCGA-Slide-Reports.csv"),
  thorsson = Sys.getenv("TITAN_THORSSON", "data/raw/immunology_paper.xlsx"),
  tcga_cdr = Sys.getenv("TITAN_TCGA_CDR", "data/raw/TCGA-CDR-SupplementalTableS1.xlsx"),
  bailey = Sys.getenv("TITAN_BAILEY", "data/raw/mmc1.xlsx"),
  aneuploidy = Sys.getenv("TITAN_ANEUPLOIDY", "data/raw/aneuploidy_mmc2.xlsx"),
  oncogenic = Sys.getenv("TITAN_ONCOGENIC", "data/raw/oncogenic_mmc4.xlsx"),
  fusion = Sys.getenv("TITAN_FUSION", "data/raw/fusion_mmc2.xlsx"),
  msi_subset = Sys.getenv("TITAN_MSI_SUBSET", "data/raw/msi_subset.xlsx")
)

