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
outcomes. Every primary, permutation, repeated, sensitivity and final-model PLS
fit uses CPU rSVD exclusively, with 10 oversampling vectors, two power
iterations and an explicit fit seed. Repeated nested
validation therefore reflects both partition and rSVD-seed variation.

Thorsson Nonsilent Mutation Rate, Silent Mutation Rate, SNV Neoantigens,
Indel Neoantigens and Number of Segments, together with Gao fusion burden,
are analysed as `log1p(x)`. Other continuous outcomes remain in source units;
reported RMSE follows the analysed scale.

## Eligibility and multiplicity

Continuous cancer-target pairs require at least 50 non-missing patients.
Binary pairs require at least 20 positive and 20 negative patients. All
eligible pairs remain in multiplicity correction. Because each cancer defines
a separate prediction screen and model-use population, primary Benjamini–
Hochberg control is calculated separately for continuous and binary outcomes
within cancer and prespecified endpoint family. A stricter q-value across all
cancers within the same outcome type and endpoint family is retained as a
sensitivity analysis. Effect-gated pairs not permuted are assigned p=1. A
discovery is not called on nominal p-values alone.

Permutation evaluation uses a conservative sequential stopping rule. The
99-permutation stage is a checkpoint; every effect-qualified endpoint is then
refined toward 999 permutations. During the final stage, an endpoint stops
after 49 null statistics are at least as extreme as observed, because even zero
further exceedances would give the finite p-value `(49+1)/(999+1)=0.05`.
Stopped endpoints are assigned `p=1`; actual attempted counts and stopping
status are retained. Early-stopped 99-permutation jobs resume from their exact
attempted count, so no permutation indices are skipped. The shortcut is
conservative for raw p<0.05 and cannot remove an endpoint capable of passing
the subsequent FDR criterion. `TITAN_RUN_999=false` is available only for pilot
runs and does not reproduce the final atlas.

The completed-test minimum p-value is 0.001. This supports the prespecified
within-cancer screens but limits attainable q-values for large across-cancer
families. The global family correction is therefore a deliberately strict,
resolution-limited sensitivity analysis; non-passage is not interpreted as
evidence that an endpoint contains no biological signal.

## Participant characteristics

The TCGA Clinical Data Resource is linked by participant barcode for
descriptive reporting only. Age, source-recorded gender and race, and broad
stage are summarized overall and by cancer with their missingness. These
variables are not supplied to a predictor. No demographic subgroup model
comparison is prespecified because molecular coverage and subgroup sizes vary
substantially across the cancer-specific endpoint screens.

## Robustness

Within-cancer screen-positive models are repeated across five independently
seeded nested 5x5 cross-validations. Collection-site grouped validation and a
first-slide versus mean-pool sensitivity analysis are reported separately. No
pathology-report text is used as a predictor.
