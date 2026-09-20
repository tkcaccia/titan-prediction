# Result-file codebook

## Primary atlases

`results/tables/continuous_screen.csv` contains one row per eligible
cancer–continuous-endpoint pair. Primary performance is `q2`; `rmse` and
`spearman` are secondary. `predictions/continuous_oof_predictions.rds` stores
the corresponding patient-level observed and outer-fold predicted values.

`results/tables/binary_screen.csv` contains one row per eligible cancer–binary
endpoint. Primary performance is `balanced_accuracy` and the effect used for
tiering is `adjusted_balanced_accuracy = 2 × balanced_accuracy − 1`.
Patient-level outer-fold predictions are stored separately.

The binary screen also carries revision-added operating-rule metadata.
`primary_binary_decision_rule` identifies the empirical outer-training-prior
LDA call. `equal_prior_*` fields describe equal-prior LDA; `optimized_*`
fields describe component count and a decision threshold selected only from
pooled inner held-out scores. Alternative-rule crossings are sensitivity
results, not alternative permutation/FDR-qualified candidate sets.

`binary_decision_rule_sensitivity.csv` contains all 459 TITAN screen rows and
all 426 matched binary tasks for each of TITAN, Giga-SSL and Prov-GigaPath.
The summary file gives all-task, near-threshold and union-positive views. The
membership-change file retains every gain or loss at balanced accuracy 0.60;
the fold-threshold file records outer class counts, inner objectives, selected
components and training-only thresholds.

`foundation_model_fold_stability_selection.csv` defines the 560-task,
revision-added fold audit: all primary union-positive pairs plus tasks within
±0.05 of Q²=0.20 or balanced accuracy=0.60 for at least one representation.
`foundation_model_fold_stability_repeats.csv` contains five new matched nested
partitions for every selected task and representation. The companion
`foundation_model_crossing_stability.csv` gives per-representation crossing
proportions and continuous effect summaries;
`foundation_model_consensus_stability.csv` gives the repeated stability of the
all-three/two/specific/none class; and
`foundation_model_effect_rank_stability.csv` retains paired effect and rank
summaries without dichotomising at a threshold;
`foundation_model_winner_stability.csv` records whether the primary leading
representation remains leading across the new partitions; and
`foundation_model_pairwise_repeat_stability.csv` reports repeat-specific
paired effect differences and win counts. The two threshold-sensitivity
files cover Q² 0.10–0.30 and balanced accuracy 0.55–0.65.
`foundation_model_fold_assignment_audit.csv` records the common fold hash and
fold sizes for each task–repeat; patient-level OOF estimates are retained in
`results/predictions/foundation_model_fold_stability_oof.rds`.

`foundation_model_normalized_breadth_summary.csv` reports, by representation
and outcome type, task crossing percentages, unique endpoint-definition
coverage, unweighted macro crossing percentages across endpoint families and
cancers, and the largest contributing endpoint family. The matched atlas has
187 exact endpoint definitions (56 continuous and 131 binary), compared with
194 in the full TITAN task universe. `foundation_model_endpoint_definition_coverage.csv`
is the compact definition-level denominator summary.
`foundation_model_endpoint_cancer_retention.csv` reports every exact
family–endpoint–source definition with its eligible and retained cancer counts
and retained cancer codes. `foundation_model_programme_cancer_retention.csv`
provides the analogous summary for the endpoint dictionary's broader
`definition_group`. All four outputs are descriptive catalogue summaries;
they do not imply independence among tasks or representation-specific FDR.

`models/foundation_models/model_registry_additions.csv` contains genuinely
representation-specific Giga-SSL and Prov-GigaPath coefficient objects fitted
for the endpoint catalogue inherited from the permutation/FDR-qualified TITAN
layer. This fixed catalogue avoids selecting which objects to fit after
inspecting an alternative representation's performance. The fields
`resource_selection_basis`, `representation_specific_qualification`,
`representation_effect_threshold_crossing`, `tier_origin`, and
`model_evidence_tier` distinguish matched crossings from
tested-below-threshold reference fits. Neither category is
representation-specific permutation/FDR-qualified.

These unsuffixed metrics are the **primary screening estimates** from the
initial nested-CV run used for selection, permutation testing, and tier
assignment. Fields prefixed by `repeated_` are means across five additional
independently seeded nested-CV partitions and quantify post-selection
resampling stability. They may differ because the fold partitions and rSVD
seeds differ. `screen_positive_performance_summary.csv` additionally provides
explicit `primary_screen_*`, `repeated_minus_primary_*`,
`primary_estimate_label`, and `repeated_estimate_label` fields.

Common columns:

- `family`, `subfamily`, `tumor_type`, `endpoint`, `source`: endpoint identity;
- `n`, `positive`, `negative`: eligible patient counts;
- `ncomp`: component count selected by inner cross-validation;
- `seed`: exact validation seed;
- `p_permutation`, `permutations`, `permutation_exceedances`: finite
  patient-label permutation result;
- `permutation_attempted`, `permutation_stopped_early`: actual computation and
  conservative sequential-stopping status (early-stopped endpoints have p=1);
- `q_value`: primary Benjamini–Hochberg value within cancer and documented
  endpoint family;
- `q_value_global`: stricter sensitivity value across all cancers within the
  documented endpoint family;
- `tier`: machine-readable code retained for compatibility: A denotes a
  within-cancer screen-positive documented screening-tier-A candidate
  (q<0.05 and screening statistic≥0.40), B a screen-positive documented
  screening-tier-B candidate (q<0.05 and screening statistic from 0.20 to
  <0.40), and
  C a tested screen-negative pair. The screening statistic is Q² for continuous
  outcomes and 2×balanced accuracy−1 for binary outcomes; the tiers are
  prioritisation rules, not clinical or generally established effect categories;
- `fastPLS_version`, `backend`, `svd_method`, `rsvd_oversample`, `rsvd_power`:
  software version, computation backend and seeded rSVD configuration used for
  the checkpoint.

Models below the screening-tier-B threshold are not permuted and conservatively
retain `p_permutation=1`; they remain in the multiplicity denominator.

## Endpoint provenance dictionary

`endpoint_dictionary.csv` has one row per eligible cancer–endpoint test and a
stable `target_id`. It classifies each target as a directly observed genomic
alteration, sequencing-derived continuous burden, computationally inferred
immune-cell fraction, transcriptomic signature, pathology-associated quantity
or composite genomic-context score. The file also reports source modality,
direct/inferred status, derivation algorithm, original scale, modelling
transformation, analysed and missing patients, expected measurement error,
biological interpretation, assay-equivalence caveat and source reference.

`endpoint_definition_dictionary.csv` collapses repeated cancer-specific tests
to the 194 unique endpoint definitions. `endpoint_dictionary_summary.csv`
summarises the measurement classes. The `same_histology_modality` flag is true
only for TIL Regional Fraction, because that outcome was itself computationally
derived from H&E images; it is not a molecular or directly counted immune assay.

`foundation_model_provenance_stratified_summary.csv` gives matched eligible
tasks, crossings, percentages and unique-definition coverage for every
representation, outcome type and measurement class.
`foundation_model_same_histology_sensitivity.csv` distinguishes the 13
same-H&E tasks in the complete TITAN catalogue from the 11 entering the matched
three-representation benchmark, and reports continuous and total counts before
and after exclusion. `foundation_model_translational_biological_synthesis.csv`
contains only mature all-three tasks with complete grouped retention, ranked
within provenance class by the minimum primary effect across representations.
Its `interpretation_scope` field distinguishes direct genomic prediction from
agreement with derived genomic-context, immune, transcriptomic or same-H&E
phenotypes.

`morphology_context_examples.csv` contains the five-model qualitative
high/low-anchor and within-cancer nearest-neighbour retrieval. `role` separates
anchors from their closest patient-level mean-embedding neighbour, and
`embedding_cosine_similarity_to_anchor` quantifies that retrieval. Exact
representative slide IDs and TITAN-generated report text are included solely as
descriptive context. These rows are not patch-level attribution, causal
morphology, or blinded pathologist review.

## Multiplicity and evidence-maturity files

`foundation_model_evidence_maturity.csv` adds the inclusive crossing and
revision-added sample-size maturity label to every matched representation-task
row. `foundation_model_evidence_maturity_summary.csv` reports inclusive and
standard-evidence denominators and crossings in parallel. The corresponding
TITAN-only qualified-candidate files are
`titan_candidate_evidence_maturity.csv` and
`titan_candidate_evidence_maturity_summary.csv`. Continuous standard evidence
requires n≥100; binary standard evidence requires at least 50 patients per
class. These fields are descriptive and do not redefine statistical
significance.

`multiplicity_denominator_audit.csv` records each eligible TITAN test's p-value
assignment status, attempted/exceedance counts, inclusion in every BH universe,
the exact denominator sizes and recomputed q-values.
`multiplicity_p_assignment_summary.csv` distinguishes models not permuted below
the performance checkpoint from tests censored by early stopping; both receive
raw p=1. `multiplicity_denominator_summary.csv` gives the local,
across-cancer/family, outcome-wide and atlas-wide denominator ranges.

## Robustness files

- `*_repeated_nested_cv.csv`: five independently partitioned nested-CV runs;
- `foundation_model_tss_grouped_sensitivity.csv`: one row for each of 340
  union-positive tasks × three representations, containing primary, grouped and
  matched-random metrics, threshold-retention status, code counts and fold hashes;
- `foundation_model_tss_grouped_fold_audit.csv`: task-level confirmation of code
  separation, identical grouped folds across representations, exact matched-random
  outer sizes and exact binary class counts;
- `foundation_model_tss_grouped_summary.csv`: representation/outcome crossing
  denominators, retained crossings and median grouped changes;
- `foundation_model_consensus_tss_crosstab.csv`: detailed cross-tabulation of
  primary consensus, sample-size maturity, grouped retention and R1–R4 class;
- `foundation_model_internal_robustness_classification.csv`: one row per
  union-positive task with complete/partial/no grouped retention and the composite
  internal prioritisation class;
- `foundation_model_tss_code_only_outcomes.csv`: code-only cross-validated outcome
  predictability on the matched common cohort;
- `*_site_grouped_sensitivity.csv`: TCGA tissue-source-site-grouped folds;
- `*_slide_pooling_sensitivity.csv`: lexicographically first slide compared
  with the documented patient mean pool;
- `continuous_median_pooling_sensitivity.csv` and
  `binary_median_pooling_sensitivity.csv`: coordinate-wise median pooling
  refitted under the original TITAN candidate settings;
- `median_pooling_sensitivity_summary.csv`: outcome-level performance deltas,
  rank concordance and threshold retention for median versus mean pooling;
- `slide_embedding_heterogeneity_patient_level.csv`: per-representation
  within-patient pairwise cosine dispersion, mean-versus-median centroid
  distance and maximum leave-one-slide-out centroid change;
- `slide_embedding_heterogeneity_summary.csv`: multi-slide-patient summaries;
- `sarc_maximum_slide_patient_exclusion_*.csv`: all SARC candidates refitted
  after removing TCGA-DX-AB2L before fold construction;
- `pathology_qc_no_residual_patient_audit.csv` and
  `pathology_qc_no_residual_patient_summary.csv`: non-adjudicated generated-text
  flags reported at patient as well as slide level;
- `nonadjudicated_no_residual_exclusion_*.csv`: all screen-positive models in
  the four affected cancers refitted after removing the six flagged patients,
  with threshold retention, highlighted-model membership and a descriptive
  material-change flag;
- `molecular_slide_linkage_audit.csv`: unique covered patients, sample-barcode
  concordance and source-specific unresolved block/aliquot label noise;
- `pls1_vs_pls2_inflammation*.csv`: matched secondary comparison on identical
  complete-case patients and folds;
- `prior_mutation_literature_crosswalk.csv`: study-level prior claims joined to
  the current mutation atlas;
- `prior_mutation_accuracy_comparison.csv`: report-level prior AUROC and current
  balanced accuracy shown side by side; the metrics are not directly
  subtractable;
- `supported_mutation_novelty.csv`: every current within-cancer screen-positive mutation pair
  classified as previously reported/recovered or atlas-nominated because it was
  absent from the documented exact-pair crosswalk;
- `source_manifest.csv`: source labels, DOIs, filenames, sizes and SHA-256
  digests; cBioPortal download URLs are in `cbioportal_download_manifest.csv`;
- `software_manifest.csv`: installed versions, available remote commit
  metadata and the explicitly pinned fastPLS/TCGAmutations sources.

## Model registry

`models/model_registry.csv` indexes locally generated research models. The RDS
objects include the exact input feature order and checksum, training ranges,
aggregation rule, endpoint transformation and output units, class coding and
priors, prediction rule, calibration and external-validation status, exact
fastPLS version and Git commit, computation backend, and research-only intended
use. The registry also records the exclusive rSVD configuration (10
32 oversampling vectors and five power iterations, the fastPLS 0.3 defaults)
and an analysis fingerprint
binding the artifact to code, data, configuration and software. They are
ignored by Git by default pending clarification of TITAN-derived-artifact
redistribution rights; the fitting and inference code is public.

## Participant characteristics

`participant_characteristics_by_cancer.csv` contains aggregate TCGA Clinical
Data Resource coverage, age median/IQR, source-recorded gender and race counts,
and broad stage counts overall and by cancer. `tcga_cdr_match_audit.csv`
documents barcode coverage and cancer-label concordance. Neither file contains
patient identifiers, and these descriptors are not model inputs or subgroup
performance estimates.
