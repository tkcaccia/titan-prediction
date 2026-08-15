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
- `tier`: A (q<0.05 and effect≥0.40), B (q<0.05 and effect 0.20–0.39), or C;
- `fastPLS_version`: software version used for the checkpoint.

Models below the Tier-B effect threshold are not permuted and conservatively
retain `p_permutation=1`; they remain in the multiplicity denominator.

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
- `supported_mutation_novelty.csv`: every current Tier-A/B mutation pair
  classified as previously reported/recovered or atlas-nominated because it was
  absent from the prespecified exact-pair crosswalk;
- `source_manifest.csv`: source paths/URLs, sizes and SHA-256 digests.

## Model registry

`models/model_registry.csv` indexes locally generated research models. The RDS
objects include the exact input feature order and aggregation rule. They are
ignored by Git by default pending clarification of TITAN-derived-artifact
redistribution rights; the fitting and inference code is public.
