# Fitted research models

`R/06_robustness_and_models.R` writes one `.rds` artifact for every within-cancer
screen-positive cancer–endpoint model and creates `model_registry.csv` with
its SHA-256 digest. `R/07f_attach_site_metadata.R` then adds the TCGA
tissue-source-site-grouped metric, change from random folds, analysed-site
count, fold-size range, inner-site-separation audit, threshold-retention status
and warning to every registry row. Each artifact contains:

- the fitted `fastPLS` object;
- the endpoint family, cancer type and outcome type;
- the exact ordered 768-feature input schema;
- the patient mean-pooling rule used for multi-slide cases;
- selected component count and training sample counts;
- endpoint transformation and output units (including explicit `log1p` units);
- training-feature ranges and moments for out-of-distribution warnings;
- class coding, fitted LDA decision behaviour and calibration status for binary
  models;
- TITAN feature-file and ordered-schema checksums;
- software version, external-validation status and a research-only intended-use
  statement, including the exact fastPLS Git commit, computation backend and
  rSVD configuration (10 oversampling vectors and two power iterations);
- an analysis fingerprint binding the artifact to the finalized screens,
  configuration, cohort schema/source and software environment.

Use `examples/predict_titan_features.R` to validate, pool and predict new TITAN
slide features. The example accepts multiple slides per patient and returns one
patient-level prediction. When the artifact contains fastPLS provenance, the
interface requires the same package version and Git build before prediction.
After slides are mean-pooled by patient, patient vectors with more than 5% of
dimensions outside the patient-level TCGA training range trigger an explicit
out-of-distribution warning. The LDA score is not a calibrated
probability and no model in this release has independent external validation.
Models below their original effect threshold under tissue-source-site grouping
must retain the registry and inference warning; grouped performance remains an
internal TCGA estimate rather than institutional or scanner-level validation.

Before export, the `fastPLS` training-score and fitted-value arrays (`Ttrain`
and `Yfit`) are removed because they are unnecessary for prediction. The
artifact retains learned preprocessing values, latent transformations,
coefficients and LDA parameters, but no patient-level training rows.

Model `.rds` files are excluded from the public analysis repository. They are
currently maintained in the separate private, access-controlled TITANPred
package repository. The public repository contains the complete fitting code
and registry; local model generation remains reproducible from the documented
inputs.
