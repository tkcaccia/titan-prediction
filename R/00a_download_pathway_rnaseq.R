suppressPackageStartupMessages(library(digest))

destination <- file.path(
  "data", "external", "xena",
  "EB++AdjustPANCAN_IlluminaHiSeq_RNASeqV2.geneExp.xena.gz"
)
url <- paste0(
  "https://pancanatlas.xenahubs.net/download/",
  "EB%2B%2BAdjustPANCAN_IlluminaHiSeq_RNASeqV2.geneExp.xena.gz"
)
expected_sha256 <-
  "a00532ec86af8c07630c618f10f6277f09c484d0a9c17db5901edf95c7714b38"

dir.create(dirname(destination), recursive = TRUE, showWarnings = FALSE)
if (!file.exists(destination)) {
  message("Downloading the public TCGA Pan-Cancer RNA-seq matrix from UCSC Xena")
  download.file(url, destination, mode = "wb", quiet = FALSE)
}

observed_sha256 <- digest(destination, algo = "sha256", file = TRUE)
if (!identical(observed_sha256, expected_sha256)) {
  stop(
    "Unexpected UCSC Xena RNA-seq checksum. Expected ", expected_sha256,
    "; observed ", observed_sha256
  )
}
message("UCSC Xena pathway source verified: ", observed_sha256)
