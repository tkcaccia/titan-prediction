suppressPackageStartupMessages(library(data.table))

base <- fread("models/model_registry.csv")
base[, foundation_model := "TITAN"]
base_inventory <- base[, .(
  fitted_models = .N,
  evidential_role = "permutation/FDR-qualified TITAN atlas candidates"
), by = .(foundation_model, outcome_type, family)]

additional_path <- "models/foundation_models/model_registry_additions.csv"
additional_inventory <- if (file.exists(additional_path)) {
  additional <- fread(additional_path)
  additional[, .(
    fitted_models = .N,
    evidential_role = paste0(
      "representation-specific coefficients for the shared TITAN-qualified matched-eligible target universe; ",
      "object presence is independent of this representation's crossing status and is not representation-specific permutation/FDR qualification"
    )
  ), by = .(foundation_model, outcome_type, family)]
} else data.table()

inventory <- rbindlist(
  list(base_inventory, additional_inventory), use.names = TRUE, fill = TRUE
)
setorder(inventory, foundation_model, outcome_type, family)
fwrite(inventory, "data/reference/model_inventory_by_representation_family.csv")
print(inventory[, .(fitted_models = sum(fitted_models)), by = foundation_model])
