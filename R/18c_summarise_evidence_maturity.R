.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages(library(data.table))

# Evidence maturity is a descriptive sample-size label. It does not change the
# inclusive eligibility rules, crossing thresholds, p-values or FDR decisions.
matched <- fread("results/tables/foundation_model_matched_screen.csv")
matched[, effect_threshold_crossing := fifelse(
  outcome_type == "continuous", q2 >= 0.20, auc >= 0.60
)]
matched[, standard_evidence := fifelse(
  outcome_type == "continuous", n >= 100L,
  positive >= 50L & negative >= 50L
)]
matched[, evidence_maturity := fifelse(
  standard_evidence, "standard_evidence", "limited_evidence"
)]

matched_summary <- matched[, .(
  inclusive_eligible_tasks = .N,
  inclusive_crossings = sum(effect_threshold_crossing),
  inclusive_crossing_percent = 100 * mean(effect_threshold_crossing),
  standard_evidence_eligible_tasks = sum(standard_evidence),
  standard_evidence_crossings = sum(
    standard_evidence & effect_threshold_crossing
  ),
  standard_evidence_crossing_percent_of_standard_eligible =
    100 * sum(standard_evidence & effect_threshold_crossing) /
      sum(standard_evidence),
  standard_evidence_percent_of_inclusive_crossings =
    100 * sum(standard_evidence & effect_threshold_crossing) /
      sum(effect_threshold_crossing),
  limited_evidence_eligible_tasks = sum(!standard_evidence),
  limited_evidence_crossings = sum(
    !standard_evidence & effect_threshold_crossing
  )
), by = .(foundation_model, outcome_type)]

continuous <- fread("results/tables/continuous_screen.csv")
binary <- fread("results/tables/binary_screen.csv")
titan_candidates <- rbindlist(list(
  continuous[tier %chin% c("A", "B"), .(
    outcome_type = "continuous", family, tumor_type, endpoint, n,
    positive = NA_integer_, negative = NA_integer_,
    standard_evidence = n >= 100L
  )],
  binary[tier %chin% c("A", "B"), .(
    outcome_type = "binary", family, tumor_type, endpoint, n,
    positive, negative,
    standard_evidence = positive >= 50L & negative >= 50L
  )]
), use.names = TRUE, fill = TRUE)
titan_candidates[, evidence_maturity := fifelse(
  standard_evidence, "standard_evidence", "limited_evidence"
)]
titan_summary <- titan_candidates[, .(
  inclusive_permutation_fdr_qualified_candidates = .N,
  standard_evidence_candidates = sum(standard_evidence),
  limited_evidence_candidates = sum(!standard_evidence),
  standard_evidence_percent = 100 * mean(standard_evidence)
), by = outcome_type]

setorder(matched, foundation_model, outcome_type, family, tumor_type, endpoint)
fwrite(matched, "results/tables/foundation_model_evidence_maturity.csv")
fwrite(matched_summary,
       "results/tables/foundation_model_evidence_maturity_summary.csv")
fwrite(titan_candidates,
       "results/tables/titan_candidate_evidence_maturity.csv")
fwrite(titan_summary,
       "results/tables/titan_candidate_evidence_maturity_summary.csv")
