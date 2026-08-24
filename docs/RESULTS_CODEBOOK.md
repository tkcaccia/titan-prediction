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

Common columns:

- `family`, `subfamily`, `tumor_type`, `endpoint`, `source`: endpoint identity;
- `n`, `positive`, `negative`: eligible patient counts;
- `ncomp`: component count selected by inner cross-validation;
- `seed`: exact validation seed;
- `p_permutation`, `permutations`, `permutation_exceedances`: finite
  patient-label permutation result;
- `permutation_attempted`, `permutation_stopped_early`: actual computation and
  conservative sequential-stopping status (early-stopped endpoints have p=1);
- `q_value`: primary Benjamini–Hochberg value within cancer and prespecified
  endpoint family;
- `q_value_global`: stricter sensitivity value across all cancers within the
  prespecified endpoint family;
- `tier`: machine-readable code retained for compatibility: A denotes a
  within-cancer screen-positive higher-effect candidate (q<0.05 and
  effect≥0.40), B a screen-positive moderate-effect candidate (q<0.05 and
  effect 0.20–0.39), and C a tested screen-negative pair;
- `fastPLS_version`, `backend`, `svd_method`, `rsvd_oversample`, `rsvd_power`:
  software version, computation backend and seeded rSVD configuration used for
  the checkpoint.

Models below the moderate-effect threshold are not permuted and conservatively
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

`morphology_context_examples.csv` contains the five-model qualitative
high/low-anchor and within-cancer nearest-neighbour retrieval. `role` separates
anchors from their closest patient-level mean-embedding neighbour, and
`embedding_cosine_similarity_to_anchor` quantifies that retrieval. Exact
representative slide IDs and TITAN-generated report text are included solely as
descriptive context. These rows are not patch-level attribution, causal
morphology, or blinded pathologist review.

## Robustness files

- `*_repeated_nested_cv.csv`: five independently partitioned nested-CV runs;
- `*_site_grouped_sensitivity.csv`: TCGA tissue-source-site-grouped folds;
- `*_slide_pooling_sensitivity.csv`: lexicographically first slide compared
  with the prespecified patient mean pool;
- `pls1_vs_pls2_inflammation*.csv`: matched secondary comparison on identical
  complete-case patients and folds;
- `prior_mutation_literature_crosswalk.csv`: study-level prior claims joined to
  the current mutation atlas;
- `prior_mutation_accuracy_comparison.csv`: report-level prior AUROC and current
  balanced accuracy shown side by side; the metrics are not directly
  subtractable;
- `supported_mutation_novelty.csv`: every current within-cancer screen-positive mutation pair
  classified as previously reported/recovered or atlas-nominated because it was
  absent from the prespecified exact-pair crosswalk;
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
oversampling vectors and two power iterations) and an analysis fingerprint
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
