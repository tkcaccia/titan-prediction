#!/usr/bin/env Rscript

# Synchronize the code, registry and fitted-object licensing boundaries after
# the PathoFMPred source-code relicensing. This script changes metadata only;
# it does not modify fitted coefficients, predictions or performance results.

project_root <- normalizePath(file.path(dirname(commandArgs(FALSE)[1L]), ".."),
                              mustWork = FALSE)
if (!file.exists(file.path(project_root, "DESCRIPTION"))) {
  project_root <- normalizePath(getwd())
}
package_root <- normalizePath(file.path(project_root, "..", "PathoFMPred-public"),
                              mustWork = FALSE)
private_root <- normalizePath(file.path(project_root, "..", "TITANPred"),
                              mustWork = FALSE)

titan_status <- paste(
  "private TITAN-derived artifact; non-commercial academic research only;",
  "public redistribution prohibited unless the TITAN rights holder grants permission"
)
public_status <- paste(
  "optional public PathoFMPred download under separate CC BY 4.0",
  "downstream-asset terms; upstream notices remain applicable"
)
titan_scope <- paste(
  "MIT-licensed public source, registry and synthetic fixture; TITAN fitted",
  "object remains private and restricted by upstream terms"
)
public_scope <- paste(
  "MIT-licensed public source and synthetic fixture; full Giga-SSL and",
  "Prov-GigaPath objects are explicit checksum-verified downloads under",
  "separate CC BY 4.0 downstream-asset terms and applicable upstream notices"
)

update_registry <- function(registry) {
  if (!"foundation_model" %in% names(registry)) {
    registry$foundation_model <- "TITAN"
  }
  is_titan <- registry$foundation_model == "TITAN"
  registry$redistribution_status <- ifelse(is_titan, titan_status, public_status)
  registry$public_release_scope <- ifelse(is_titan, titan_scope, public_scope)
  registry$source_code_license <- "MIT"
  registry$registry_and_result_license <- "CC BY 4.0"
  registry$model_asset_license <- ifelse(
    is_titan,
    "not relicensed; upstream TITAN restricted terms apply",
    "CC BY 4.0 downstream-asset terms, subject to applicable upstream notices"
  )
  registry$upstream_terms_summary <- ifelse(
    is_titan,
    "TITAN CC BY-NC-ND 4.0 terms identify output-trained models as derivatives and prohibit redistribution without permission",
    ifelse(
      registry$foundation_model == "GigaSSL",
      "Giga-SSL repository MIT terms; TCGA and endpoint-source attribution remains required",
      "Prov-GigaPath Apache-2.0 code and CC BY 4.0 TCGA embedding-dataset notices remain applicable"
    )
  )
  registry
}

csv_paths <- c(
  file.path(project_root, "models", "model_registry.csv"),
  file.path(project_root, "models", "foundation_models", "model_registry_additions.csv"),
  file.path(package_root, "inst", "extdata", "model_registry.csv"),
  file.path(private_root, "inst", "extdata", "model_registry.csv")
)
for (path in csv_paths[file.exists(csv_paths)]) {
  registry <- utils::read.csv(path, check.names = FALSE, stringsAsFactors = FALSE)
  utils::write.csv(update_registry(registry), path, row.names = FALSE, na = "")
  message("Updated registry metadata: ", path)
}

object_paths <- c(
  file.path(package_root, "inst", "models", "pathofmpred_gigassl_example.rds"),
  file.path(private_root, "inst", "models", "pathofmpred_titan.rds"),
  file.path(private_root, "inst", "models", "pathofmpred_gigassl.rds"),
  file.path(private_root, "inst", "models", "pathofmpred_provgigapath.rds")
)
for (path in object_paths[file.exists(object_paths)]) {
  object <- readRDS(path)
  object$registry <- update_registry(object$registry)
  object$provenance$source_code_license <- "MIT"
  object$provenance$registry_and_result_license <- "CC BY 4.0"
  object$provenance$model_asset_license <- unique(object$registry$model_asset_license)
  object$provenance$license_notice <- paste(
    "The MIT license covers contributor-authored PathoFMPred source code only.",
    "See inst/licenses/MODEL_ACCESS.md for model-asset and upstream terms."
  )
  saveRDS(object, path, compress = "xz")
  message("Updated fitted-object metadata: ", path)
}
