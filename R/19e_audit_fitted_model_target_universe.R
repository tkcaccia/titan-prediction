suppressPackageStartupMessages(library(data.table))

screen_path <- "results/tables/foundation_model_matched_screen.csv"
titan_registry_path <- "models/model_registry.csv"
alternative_registry_path <- "models/foundation_models/model_registry_additions.csv"

stopifnot(file.exists(screen_path), file.exists(titan_registry_path),
          file.exists(alternative_registry_path))

screen <- fread(screen_path)
titan_registry <- fread(titan_registry_path)
alternative_registry <- fread(alternative_registry_path)

# The source registries intentionally have different evidence fields. Avoid
# polluting either schema when they are temporarily row-bound for the audit.
alternative_only_fields <- c(
  "screen_q2", "screen_rmse", "screen_spearman",
  "screen_balanced_accuracy", "repeated_q2", "repeated_rmse",
  "repeated_spearman", "repeated_sensitivity", "repeated_specificity",
  "repeated_balanced_accuracy", "repeated_auc", "primary_estimate_label",
  "repeated_estimate_label", "repeated_minus_primary_primary_metric",
  "resource_selection_basis", "representation_specific_qualification",
  "titan_catalogue_tier", "tier_origin",
  "representation_effect_threshold_crossing"
)
titan_registry[, (intersect(names(titan_registry),
                             alternative_only_fields)) := NULL]
base_only_fields <- c(
  "continuous_evidence_category", "continuous_repeat_q2_sd",
  "continuous_prediction_repeat_spearman",
  "continuous_selected_components_median",
  "continuous_selected_components_min", "continuous_selected_components_max",
  "continuous_outer_fits_at_ceiling", "continuous_outer_fits",
  "continuous_outer_fit_ceiling_fraction",
  "continuous_any_outer_fit_at_ceiling"
)
alternative_registry[, (intersect(names(alternative_registry),
                                   base_only_fields)) := NULL]
titan_registry[, foundation_model := "TITAN"]
registry <- rbindlist(list(titan_registry, alternative_registry),
                      use.names = TRUE, fill = TRUE)

# Make regeneration idempotent when the source registries already contain a
# previous audit snapshot.
enrichment_fields <- c(
  "matched_representation_effect_threshold_crossing",
  "crossing_object_coverage_note",
  "controlled_object_target_universe",
  "matched_effect_threshold_definition",
  "complete_operationalization_of_multi_representation_atlas",
  "public_model_free_shell_endpoint_inference",
  "public_release_scope"
)
drop_enrichment <- names(registry)[
  names(registry) %chin% enrichment_fields |
    sub("[.][xy]$", "", names(registry)) %chin% enrichment_fields
]
if (length(drop_enrichment)) registry[, (drop_enrichment) := NULL]

screen[, representation_effect_threshold_crossing := fifelse(
  outcome_type == "continuous", q2 >= 0.20,
  auc >= 0.60
)]

key_cols_screen <- c("outcome_type", "family", "tumor_type", "endpoint")
key_cols_registry <- c("outcome_type", "family", "cancer_type", "endpoint")
screen[, target_key := do.call(paste, c(.SD, sep = "\u001f")), .SDcols = key_cols_screen]
registry[, target_key := do.call(paste, c(.SD, sep = "\u001f")), .SDcols = key_cols_registry]

stopifnot(!anyDuplicated(screen[, .(foundation_model, target_key)]))
stopifnot(!anyDuplicated(registry[, .(foundation_model, target_key)]))

matched_lookup <- screen[, .(
  foundation_model, target_key, matched_task = TRUE,
  representation_effect_threshold_crossing,
  matched_q2 = q2,
  matched_balanced_accuracy = balanced_accuracy,
  matched_auroc = auc
)]
registry_audit <- merge(
  registry[, .(foundation_model, outcome_type, family, cancer_type, endpoint,
               model_id, target_key, resource_selection_basis,
               representation_specific_qualification, default_inference,
               redistribution_status)],
  matched_lookup,
  by = c("foundation_model", "target_key"), all.x = TRUE
)
registry_audit[is.na(matched_task), matched_task := FALSE]
registry_audit[, object_crossed_representation_threshold := fifelse(
  matched_task, representation_effect_threshold_crossing, NA
)]
registry_audit[, resource_scope := fifelse(
  foundation_model == "TITAN",
  "full permutation/FDR-qualified TITAN candidate layer",
  "shared TITAN-qualified targets eligible in the matched common cohort; not the representation-specific crossing set"
)]
registry_audit[, complete_operationalization_of_representation_atlas := FALSE]

summary_rows <- list()
for (model in c("TITAN", "GigaSSL", "ProvGigaPath")) {
  for (type in c("continuous", "binary")) {
    s <- screen[foundation_model == model & outcome_type == type]
    r <- registry_audit[foundation_model == model & outcome_type == type]
    crossing_keys <- s[representation_effect_threshold_crossing == TRUE, target_key]
    object_keys <- r$target_key
    summary_rows[[length(summary_rows) + 1L]] <- data.table(
      foundation_model = model,
      outcome_type = type,
      matched_tasks = nrow(s),
      matched_effect_threshold_crossings = length(crossing_keys),
      controlled_objects = nrow(r),
      controlled_objects_in_matched_analysis = sum(r$matched_task),
      controlled_objects_not_in_matched_analysis = sum(!r$matched_task),
      controlled_objects_crossing_for_representation = sum(
        r$object_crossed_representation_threshold %in% TRUE
      ),
      controlled_objects_below_threshold_for_representation = sum(
        r$object_crossed_representation_threshold %in% FALSE
      ),
      representation_crossings_with_controlled_object = sum(crossing_keys %in% object_keys),
      representation_crossings_without_controlled_object = sum(!crossing_keys %in% object_keys),
      crossing_object_coverage_percent = 100 * sum(crossing_keys %in% object_keys) /
        max(1L, length(crossing_keys)),
      complete_operationalization_of_representation_atlas = FALSE,
      object_target_selection_rule = if (model == "TITAN") {
        "all permutation/FDR-qualified TITAN candidates from the larger TITAN-only screen"
      } else {
        sprintf(
          paste(
            "the %d TITAN-qualified %s targets eligible in the matched common",
            "cohort, irrespective of this representation's crossing status"
          ),
          nrow(r), type
        )
      }
    )
  }
}
inventory_reconciliation <- rbindlist(summary_rows)

alternative_sets <- split(
  registry_audit[foundation_model != "TITAN", target_key],
  registry_audit[foundation_model != "TITAN", foundation_model]
)
stopifnot(setequal(alternative_sets[["GigaSSL"]], alternative_sets[["ProvGigaPath"]]))
for (model in c("GigaSSL", "ProvGigaPath")) {
  expected_keys <- intersect(
    registry_audit[foundation_model == "TITAN", target_key],
    screen[foundation_model == model, target_key]
  )
  observed_keys <- registry_audit[foundation_model == model, target_key]
  stopifnot(setequal(observed_keys, expected_keys))
}

fwrite(inventory_reconciliation,
       "results/tables/fitted_model_inventory_reconciliation.csv")
fwrite(registry_audit,
       "results/tables/fitted_model_target_universe_audit.csv")

# Persist the distinction between object availability and matched-atlas
# threshold crossing in every controlled-registry row. These fields are
# descriptive resource metadata; they do not create a new evidence tier.
coverage_note <- inventory_reconciliation[, .(
  foundation_model, outcome_type,
  crossing_object_coverage_note = sprintf(
    "%d/%d representation-specific matched effect-threshold crossings have a controlled object; the registry is a partial, not complete, operationalization of this representation's matched atlas",
    representation_crossings_with_controlled_object,
    matched_effect_threshold_crossings
  )
)]
registry_enriched <- merge(
  registry,
  matched_lookup[, .(
    foundation_model, target_key,
    matched_representation_effect_threshold_crossing =
      representation_effect_threshold_crossing
  )],
  by = c("foundation_model", "target_key"), all.x = TRUE
)
registry_enriched <- merge(registry_enriched, coverage_note,
                           by = c("foundation_model", "outcome_type"),
                           all.x = TRUE)
# Prediction and reporting expose only models that crossed the threshold for
# the selected cancer and representation. Smaller-sample crossing models stay
# available only through the explicit limited-evidence opt-in. Objects tested
# below the threshold remain in the raw registry for audit but never enter
# inference. TITAN objects outside the common matched cohort retain their
# supporting permutation/FDR-qualified TITAN status.
registry_enriched[, supporting_titan_crossing :=
  foundation_model == "TITAN" &
    is.na(matched_representation_effect_threshold_crossing)]
registry_enriched[, default_inference :=
  (matched_representation_effect_threshold_crossing %in% TRUE |
     supporting_titan_crossing %in% TRUE) &
    !grepl("^exploratory_limited", model_evidence_tier)]
registry_enriched[, supporting_titan_crossing := NULL]
registry_enriched[, controlled_object_target_universe := fifelse(
  foundation_model == "TITAN",
  "full permutation/FDR-qualified TITAN candidate layer",
  "shared TITAN-qualified targets eligible in the matched common cohort; object presence is independent of this representation's crossing status"
)]
registry_enriched[, matched_effect_threshold_definition :=
  "Q2 >= 0.20 for continuous tasks; AUROC >= 0.60 for binary tasks"]
registry_enriched[, complete_operationalization_of_multi_representation_atlas := FALSE]
registry_enriched[, public_model_free_shell_endpoint_inference := FALSE]
registry_enriched[, public_release_scope := fifelse(
  foundation_model == "TITAN",
  paste(
    "MIT-licensed public source, registry and synthetic fixture; TITAN fitted",
    "object remains private and restricted by upstream terms"
  ),
  paste(
    "MIT-licensed public source and synthetic fixture; full Giga-SSL and",
    "Prov-GigaPath objects are explicit checksum-verified downloads under",
    "separate CC BY 4.0 downstream-asset terms and applicable upstream notices"
  )
)]
registry_enriched[, target_key := NULL]

titan_enriched <- registry_enriched[foundation_model == "TITAN"]
alternative_enriched <- registry_enriched[foundation_model != "TITAN"]
titan_keep <- setdiff(names(titan_enriched), alternative_only_fields)
alternative_keep <- setdiff(names(alternative_enriched), base_only_fields)
fwrite(titan_enriched[, ..titan_keep], titan_registry_path)
fwrite(alternative_enriched[, ..alternative_keep], alternative_registry_path)

print(inventory_reconciliation)
