# Locked protocol for future independent evaluation

## Current status

No independent performance estimate is reported in the manuscript. All model
selection, resampling, uncertainty intervals and example outputs are derived
from TCGA. The official TITAN release provides the precomputed TCGA slide
representations used by this project; no compatible non-TCGA embedding release
with the required molecular outcomes was identified during the audit.

CPTAC-UCEC is a plausible independent cohort because the official TCIA
collection reports 250 subjects, 887 pathology whole-slide images and links to
genomic, proteomic and clinical resources. The pathology archive is about
154 GB. It has not been downloaded or inspected for model evaluation in this
project, and no CPTAC-UCEC TITAN representations have been generated.

## Models locked before external data inspection

The exact three-model subset, artifact hashes and internally derived TCGA
metrics are recorded in
`data/reference/external_validation_locked_targets.csv`:

1. UCEC TP53 mutation (common binary mutation endpoint);
2. UCEC genome doubling (binary genomic-instability endpoint); and
3. UCEC aneuploidy score (continuous genomic-context endpoint).

The subset was chosen after the TCGA screen, so its TCGA performance is
selection-conditioned. It is nevertheless fixed before any external feature,
outcome or prediction is inspected.

## External evaluation rules

- Use only primary-tumour diagnostic slides from eligible CPTAC-UCEC patients.
- Extract CONCH v1.5 patch features and TITAN slide representations using the
  exact documented upstream pipeline and model weights. Record software,
  weights, magnification, patch size, quality-control rules and hashes.
- Apply the same deterministic patient-level arithmetic mean across every
  eligible diagnostic slide.
- Preserve the 768-feature order and apply the frozen fitted artifacts exactly
  as hashed in the target file.
- Do not refit model components, coefficients, class priors, calibration,
  operating thresholds or outcome cut-offs.
- Construct each outcome without viewing TITAN predictions. Use the original
  endpoint definition; if a compatible definition cannot be reconstructed,
  report that target as non-evaluable rather than substitute a data-driven
  surrogate.
- For binary endpoints, report balanced accuracy as primary and AUROC,
  sensitivity, specificity and prevalence as secondary metrics. The LDA score
  remains uncalibrated.
- For the continuous endpoint, report Q2 as primary and RMSE, Spearman
  correlation, calibration intercept and calibration slope as secondary
  metrics.
- Report patient and slide flow, molecular missingness, exclusions, multiple
  slides, outcome counts, uncertainty intervals and all three target results,
  including chance-level, failed and non-evaluable results.
- Do not update the manuscript's external-validation status until this locked
  analysis has been completed on an untouched cohort.

Official cohort source: National Cancer Institute Clinical Proteomic Tumor
Analysis Consortium, CPTAC-UCEC, The Cancer Imaging Archive,
doi:10.7937/K9/TCIA.2018.3R3JUISW.
