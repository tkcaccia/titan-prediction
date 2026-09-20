# Representation-specific reference models

The controlled PathoFMPred registry contains 2,459 genuinely
representation-specific `.rds` objects: 869 TITAN models (770 continuous and
99 binary), 795 Giga-SSL models (703 continuous and 92 binary) and 795
Prov-GigaPath models (703 continuous and 92 binary). TITAN objects represent
permutation/FDR-qualified candidates. Giga-SSL and Prov-GigaPath objects are
representation-specific reference fits for the same TITAN-qualified endpoint
catalogue; their registry rows distinguish matched effect-threshold crossings
from tested-below-threshold fits, and neither has representation-specific
permutation/FDR qualification.

`R/06_robustness_and_models.R` writes the TITAN candidate artifacts and creates
registry records with SHA-256 digests. Representation-specific package builds
add the matched Giga-SSL and Prov-GigaPath objects. Selecting
`foundation_model` changes both the validated feature schema and the actual
fitted object; this is not schema-only dispatch. `R/07f_attach_site_metadata.R` adds the full-cohort TITAN
metric grouped by TCGA tissue-source-site code, change from random folds, analysed-code
count, fold-size range, inner code-group separation audit, threshold-retention status
and warning. `R/19d_attach_matched_tss_metadata.R` separately adds the common-cohort
three-representation grouped metric, AUROC where applicable, matched-random effect,
retention status, consensus class, R1–R4 internal prioritisation class and scope warning
to every registry row; objects outside the 340 union-positive task set are explicitly
marked not evaluated rather than left ambiguous. Each artifact contains:

- the fitted `fastPLS` object;
- the endpoint family, cancer type and outcome type;
- the exact ordered input schema (768 TITAN, 512 Giga-SSL or 768 Prov-GigaPath features);
- the patient mean-pooling rule used for multi-slide cases;
- selected component count and training sample counts;
- endpoint transformation and output units (including explicit `log1p` units);
- training-feature ranges and moments for out-of-distribution warnings;
- class coding, fitted LDA decision behaviour and calibration status for binary
  models;
- TITAN feature-file and ordered-schema checksums;
- software version, external-validation status and a research-only intended-use
  statement, including the exact fastPLS Git commit, computation backend and
  rSVD configuration (the fastPLS 0.3 defaults of 32 oversampling vectors and
  five power iterations);
- an analysis fingerprint binding the artifact to the finalized screens,
  configuration, cohort schema/source and software environment.

Use the PathoFMPred tutorial to select `foundation_model`, validate, pool and
predict new slide features. The interface accepts multiple slides per patient and returns one
patient-level prediction. When the artifact contains fastPLS provenance, the
interface requires the same package version and Git build before prediction.
After slides are mean-pooled by patient, patient vectors with more than 5% of
dimensions outside the patient-level TCGA training range trigger an explicit
out-of-distribution warning. The LDA score is not a calibrated
probability and no model in this release has independent external validation.
Models below their original documented screening threshold under grouping by TCGA tissue-source-site code
must retain the registry and inference warning; grouped performance remains an
internal TCGA estimate rather than institutional or scanner-level validation.

Before export, the `fastPLS` training-score and fitted-value arrays (`Ttrain`
and `Yfit`) are removed because they are unnecessary for prediction. The
artifact retains learned preprocessing values, latent transformations,
coefficients and LDA parameters, but no patient-level training rows.

Model `.rds` files are excluded from the public analysis repository. The public
PathoFMPred package provides an MIT-licensed software interface, a small
Giga-SSL fixture and explicit checksum-verified downloads of the full Giga-SSL
and Prov-GigaPath collections under their separate downstream-asset terms.
The TITAN object remains only in the private, access-controlled repository and
is excluded from the package MIT and CC BY 4.0 grants. See the package
`inst/licenses/MODEL_ACCESS.md` file for the complete boundaries.
