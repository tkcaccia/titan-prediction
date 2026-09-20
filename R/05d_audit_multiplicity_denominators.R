.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages(library(data.table))

# This audit makes the conservative p-value assignment and every BH denominator
# explicit at the cancer-endpoint level. It does not change the primary screen.
continuous <- fread("results/tables/continuous_screen.csv")
binary <- fread("results/tables/binary_screen.csv")
saved_q <- fread("results/tables/multiplicity_sensitivity_by_endpoint.csv")

normalise_early_stop <- function(x) {
  x[is.na(permutation_stopped_early), permutation_stopped_early := FALSE]
  x
}
continuous <- normalise_early_stop(continuous)
binary <- normalise_early_stop(binary)

audit <- rbindlist(list(
  continuous[, .(
    outcome_type = "continuous", family, tumor_type, endpoint,
    performance_checkpoint_passed = is.finite(q2) & q2 >= 0.20,
    p_permutation, permutation_attempted, permutation_exceedances,
    permutation_stopped_early
  )],
  binary[, .(
    outcome_type = "binary", family, tumor_type, endpoint,
    performance_checkpoint_passed = is.finite(adjusted_balanced_accuracy) &
      adjusted_balanced_accuracy >= 0.20,
    p_permutation, permutation_attempted, permutation_exceedances,
    permutation_stopped_early
  )]
), use.names = TRUE)
expected_audit_rows <- nrow(continuous) + nrow(binary)
audit_key <- c("outcome_type", "family", "tumor_type", "endpoint")
stopifnot(
  nrow(audit) == expected_audit_rows,
  uniqueN(audit, by = audit_key) == expected_audit_rows
)

audit[, p_assignment_status := fcase(
  !performance_checkpoint_passed,
  "not_permuted_below_performance_checkpoint_p1",
  permutation_stopped_early,
  "early_stopped_significance_impossible_p1",
  default = "completed_permutation"
)]

stopifnot(
  audit[performance_checkpoint_passed == FALSE,
        all(p_permutation == 1)],
  audit[permutation_stopped_early == TRUE, all(p_permutation == 1)],
  audit[p_assignment_status == "completed_permutation",
        all(permutation_attempted == 999L)],
  all(is.finite(audit$p_permutation))
)

# Every eligible row is included in every applicable BH family. Denominator
# columns are repeated on each row so the exact multiplicity universe is
# inspectable without reconstructing groups from prose.
audit[, local_bh_denominator := .N,
      by = .(outcome_type, tumor_type, family)]
audit[, across_cancer_family_bh_denominator := .N,
      by = .(outcome_type, family)]
audit[, outcome_wide_bh_denominator := .N, by = outcome_type]
audit[, atlas_wide_bh_denominator := .N]
audit[, `:=`(
  included_in_local_bh = TRUE,
  included_in_across_cancer_family_bh = TRUE,
  included_in_outcome_wide_bh = TRUE,
  included_in_atlas_wide_bh = TRUE
)]

audit[, q_recomputed_local := p.adjust(p_permutation, method = "BH"),
      by = .(outcome_type, tumor_type, family)]
audit[, q_recomputed_across_cancer_family :=
        p.adjust(p_permutation, method = "BH"),
      by = .(outcome_type, family)]
audit[, q_recomputed_outcome_wide := p.adjust(p_permutation, method = "BH"),
      by = outcome_type]
audit[, q_recomputed_atlas_wide := p.adjust(p_permutation, method = "BH")]

audit <- merge(
  audit,
  saved_q[, .(
    outcome_type, family, tumor_type, endpoint,
    q_saved_local = q_value,
    q_saved_across_cancer_family = q_value_global,
    q_saved_outcome_wide = q_value_outcome_wide,
    q_saved_atlas_wide = q_value_atlas_wide
  )],
  by = c("outcome_type", "family", "tumor_type", "endpoint"),
  all.x = TRUE, sort = FALSE
)
stopifnot(
  nrow(audit) == expected_audit_rows,
  max(abs(audit$q_recomputed_local - audit$q_saved_local)) < 1e-12,
  max(abs(audit$q_recomputed_across_cancer_family -
            audit$q_saved_across_cancer_family)) < 1e-12,
  max(abs(audit$q_recomputed_outcome_wide -
            audit$q_saved_outcome_wide)) < 1e-12,
  max(abs(audit$q_recomputed_atlas_wide - audit$q_saved_atlas_wide)) < 1e-12
)

status_summary <- audit[, .(
  eligible_tests = .N,
  below_checkpoint_assigned_p1 = sum(
    p_assignment_status == "not_permuted_below_performance_checkpoint_p1"
  ),
  early_stopped_assigned_p1 = sum(
    p_assignment_status == "early_stopped_significance_impossible_p1"
  ),
  completed_permutation_tests = sum(
    p_assignment_status == "completed_permutation"
  ),
  completed_tests_with_999_permutations = sum(
    p_assignment_status == "completed_permutation" &
      permutation_attempted == 999L
  ),
  outcome_wide_bh_denominator = unique(outcome_wide_bh_denominator),
  atlas_wide_bh_denominator = unique(atlas_wide_bh_denominator),
  every_row_in_all_applicable_bh_denominators = all(
    included_in_local_bh & included_in_across_cancer_family_bh &
      included_in_outcome_wide_bh & included_in_atlas_wide_bh
  )
), by = outcome_type]

denominator_summary <- audit[, .(
  eligible_tests = .N,
  local_bh_families = uniqueN(paste(tumor_type, family, sep = "::")),
  local_bh_denominator_min = min(local_bh_denominator),
  local_bh_denominator_max = max(local_bh_denominator),
  across_cancer_bh_families = uniqueN(family),
  across_cancer_family_bh_denominator_min =
    min(across_cancer_family_bh_denominator),
  across_cancer_family_bh_denominator_max =
    max(across_cancer_family_bh_denominator),
  outcome_wide_bh_denominator = unique(outcome_wide_bh_denominator),
  atlas_wide_bh_denominator = unique(atlas_wide_bh_denominator)
), by = outcome_type]

setorder(audit, outcome_type, family, tumor_type, endpoint)
fwrite(audit, "results/tables/multiplicity_denominator_audit.csv")
fwrite(status_summary,
       "results/tables/multiplicity_p_assignment_summary.csv")
fwrite(denominator_summary,
       "results/tables/multiplicity_denominator_summary.csv")
