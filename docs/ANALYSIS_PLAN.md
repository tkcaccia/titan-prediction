# Locked analysis plan

## Unit of analysis and slides

The participant is the independent unit. Eligible slides are FFPE primary
tumour diagnostic slides identified by TCGA sample type `01` and `-DX` in
the filename. For each participant and each of the 768 TITAN dimensions, the
arithmetic mean across all eligible slides is calculated before any outcome
is joined. The number and identifiers of contributing slides are retained.
Molecular outcomes are likewise restricted to TCGA primary-tumour sample type
`01` before participant-level aggregation; metastatic, recurrent and normal
sample barcodes are excluded.

## Primary models

- Continuous target: one-target PLS1 regression within each cancer type.
- Binary target: one-target PLS followed by LDA within each cancer type.
- Immune multivariate sensitivity: PLS2, evaluated only on complete matched
  samples and identical folds; comparison is secondary.

Component number (1-10) is selected inside the training portion of every
outer fold. Performance is calculated exclusively from out-of-fold patient
predictions. Balanced accuracy is primary for binary outcomes; AUROC from
continuous LDA scores is secondary. Q-squared is primary for continuous
outcomes.

## Eligibility and multiplicity

Continuous cancer-target pairs require at least 50 non-missing patients.
Binary pairs require at least 20 positive and 20 negative patients. All
eligible pairs remain in multiplicity correction. Because each cancer defines
a separate prediction screen and model-use population, primary Benjamini–
Hochberg control is within cancer and prespecified endpoint family. A stricter
q-value across all cancers within each endpoint family is retained as a
sensitivity analysis. Effect-gated pairs not permuted are assigned p=1. A
discovery is not called on nominal p-values alone.

Permutation evaluation uses a conservative sequential stopping rule. During
the 99-permutation stage, an endpoint stops after five null statistics are at
least as extreme as observed, because even zero further exceedances would give
the finite p-value `(5+1)/(99+1)=0.06`. Such stopped endpoints are assigned
`p=1`. Attempted counts and stopping status are retained. Thus the shortcut is
conservative and cannot remove an endpoint capable of passing the subsequent
FDR criterion. A 999-permutation extension is available as an optional
precision analysis (`TITAN_RUN_999=true`) but is not required for the primary
cancer-specific FDR screen.

## Robustness

Supported models are repeated across five independently seeded nested 5x5
cross-validations. Collection-site grouped validation and a first-slide versus
mean-pool sensitivity analysis are reported separately. No pathology-report
text is used as a predictor.
