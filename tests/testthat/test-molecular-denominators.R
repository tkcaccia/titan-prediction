test_that("mutation targets contain only unique MC3-profiled patients", {
  root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
  target_file <- file.path(root, "data", "processed",
                           "binary_targets_mutation.rds")
  audit_file <- file.path(root, "results", "tables",
                          "mutation_coverage_audit.csv")
  skip_if_not(file.exists(target_file) && file.exists(audit_file))

  targets <- data.table::as.data.table(readRDS(target_file))
  audit <- data.table::fread(audit_file)
  expect_true(all(targets$value %in% c(0L, 1L)))
  expect_equal(
    targets[, .N, by = .(tumor_type, endpoint)][, sum(N)],
    unique(targets[, .(patient, tumor_type, endpoint)])[, .N]
  )

  represented <- unique(targets[, .(patient, tumor_type)])[
    , .(target_patients = data.table::uniqueN(patient)), by = tumor_type
  ]
  compared <- merge(
    represented,
    audit[, .(tumor_type, matched_profiled_patients)],
    by = "tumor_type", all.x = TRUE
  )
  expect_false(anyNA(compared$matched_profiled_patients))
  expect_equal(compared$target_patients, compared$matched_profiled_patients)
})

test_that("mutation variant classes are explicitly protein altering", {
  root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
  audit_file <- file.path(root, "results", "tables",
                          "mutation_variant_classification_audit.csv")
  skip_if_not(file.exists(audit_file))
  audit <- data.table::fread(audit_file)
  allowed <- c(
    "Missense_Mutation", "Nonsense_Mutation", "Nonstop_Mutation",
    "Splice_Site", "Translation_Start_Site", "Frame_Shift_Del",
    "Frame_Shift_Ins", "In_Frame_Del", "In_Frame_Ins"
  )
  expect_true(all(audit$Variant_Classification %in% allowed))
  expect_true(all(audit$retained_as_protein_altering))
})

test_that("slide multiplicity audit is patient-safe", {
  root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
  audit_file <- file.path(root, "results", "tables",
                          "patient_slide_multiplicity_by_cancer.csv")
  skip_if_not(file.exists(audit_file))
  audit <- data.table::fread(audit_file)
  expect_equal(sum(audit$patients), 9404L)
  expect_equal(sum(audit$multi_slide_patients), 843L)
  expect_equal(sum(audit$patients_with_multiple_primary_sample_barcodes), 0L)

  coverage_file <- file.path(root, "results", "tables",
                             "slide_report_coverage_audit.csv")
  coverage <- data.table::fread(coverage_file)
  expect_equal(sum(coverage$eligible_slides), 11449L)
  expect_equal(sum(coverage$exact_report_matched_slides), 10106L)
  expect_equal(sum(coverage$unmatched_slides), 1343L)
  expect_equal(sum(coverage$exact_report_matched_slides +
                     coverage$unmatched_slides),
               sum(coverage$eligible_slides))
})

test_that("participant characteristics cover the patient cohort without cancer-label conflict", {
  root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
  characteristics_file <- file.path(
    root, "results", "tables", "participant_characteristics_by_cancer.csv"
  )
  match_file <- file.path(root, "results", "tables", "tcga_cdr_match_audit.csv")
  skip_if_not(file.exists(characteristics_file) && file.exists(match_file))
  characteristics <- data.table::fread(characteristics_file)
  match_audit <- data.table::fread(match_file)
  overall <- characteristics[tumor_type == "Overall"]
  expect_equal(overall$patients, 9404L)
  expect_equal(overall$cdr_matched, 9385L)
  expect_equal(overall$female + overall$male + overall$gender_missing,
               overall$patients)
  expect_equal(overall$race_available + overall$race_missing,
               overall$patients)
  expect_equal(overall$stage_available + overall$stage_missing_or_other,
               overall$patients)
  expect_equal(sum(match_audit$discordant_cancer_labels), 0L)
})
