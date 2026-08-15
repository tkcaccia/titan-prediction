# TITAN prediction atlas

Reproducible, patient-level prediction of molecular, immune and genomic
features from frozen TITAN whole-slide embeddings across 32 TCGA cancer
types.

Public repository: https://github.com/tkcaccia/titan-prediction

## Manuscript package

- [Main manuscript](manuscript/manuscript_JTM_patient_level_TITAN.docx)
- [Supplementary material](manuscript/supplementary_material_JTM.docx)
- [Response to the original reviewer comments](manuscript/response_to_reviewer_JTM.docx)
- [Journal-style internal reviewer assessment](manuscript/reviewer_report_JTM.docx)

## Analysis scope

The primary question is cancer-specific: **which individual molecular or
inflammatory features can be predicted from histology-derived TITAN
representations?** The pipeline evaluates:

- tissue-specific driver mutations;
- 39 immune/inflammatory measurements plus 11 genomic-context scores from
  Thorsson et al. (50 continuous endpoints in total);
- ten oncogenic pathway alteration indicators from Sanchez-Vega et al.;
- MANTIS/MSIsensor microsatellite-instability scores and eligible binary MSI
  endpoints;
- aneuploidy score, amplification/deletion burdens and genome doubling;
- fusion burden, any called fusion and eligible recurrent fusion pairs.

Mutation and other binary endpoints use PLS latent variables followed by LDA;
continuous endpoints use PLS1 regression. The matched PLS1-versus-PLS2
comparison for coherent inflammatory blocks is secondary and is reported in
the supplementary material.

## Multiple slides per patient

The patient is the analysis unit. All eligible primary-tumour diagnostic
slides (`01`, `DX`) for a participant are averaged feature-by-feature before
model fitting. This deterministic mean-pooling rule uses no outcome data,
keeps every participant in exactly one validation fold and avoids the
arbitrary choice of a first slide. Slide-level and case-level report text is
used only to audit slide provenance and is never supplied to a predictor.

## Reproducibility

1. Install R 4.6 or later and run `R/00_bootstrap.R`.
2. Copy `config/paths.example.R` to `config/paths.local.R` and set the local
   paths to the source files.
3. Run `Rscript R/run_all.R` from the repository root.

The default primary calibration uses up to 99 permutations per effect-qualified
endpoint and controls FDR within cancer and endpoint family; a stricter
across-cancer q-value is also written. Set `TITAN_RUN_999=true` only when an
optional higher-resolution permutation sensitivity is required. On Apple
Silicon, `TITAN_BACKEND=metal` is supported by fastPLS when Metal is available,
but benchmark it first: for the present 768-feature nested-CV workload the CPU
backend was faster.

After the R pipeline finishes, build the submission documents with:

```bash
python3 manuscript/build_documents.py
```

This produces the main manuscript, supplementary material and point-by-point
reviewer response under `manuscript/`. Numerical statements and tables are read
directly from released CSV files; they are not separately hand-entered.

Large source datasets and TITAN embeddings are not redistributed here.
`R/00_download_cbioportal.R` retrieves public MSI clinical fields from the
cBioPortal Datahub and records URLs and SHA-256 digests. Every result table
contains the endpoint family, cancer type, eligibility counts, validation
seed and software version.

## Deploying a fitted model

See `examples/predict_titan_features.R`. The example accepts one or more
TITAN slide embeddings per patient, validates all 768 dimensions, applies
the same mean pooling used during training, and returns patient-level
predictions.

Every exported RDS object includes the exact 768-column feature order, slide
aggregation rule, cancer type, endpoint, selected component count, class counts
where applicable, fastPLS version and research-only intended-use statement.

PLS and PLS–LDA are parametric models: external prediction needs the learned
preprocessing values, latent weights, coefficients and classification
parameters, but not the patient-level training embeddings or outcomes. This is
a practical data-minimisation advantage over reference-set methods such as
k-nearest neighbours, whose inference requires stored training examples. It is
not a guarantee of privacy, transportability or redistribution permission.

Fitted objects are generated under `models/` but are not committed by
default. TITAN's upstream terms describe models trained on TITAN outputs as
derivatives and restrict redistribution. Public release of fitted model
objects therefore requires written permission or an explicit compatible
license from the TITAN rights holder. The complete fitting and inference
code remains public and reproducible.

## Intended use

Research use only. The models are internally validated retrospective TCGA
research models, not medical devices and not suitable for patient care.

## License and attribution

Repository code is released under GPL-3.0 because `fastPLS` is GPL-3.0.
Source data and TITAN-derived artifacts remain subject to their respective
upstream terms. See `provenance/SOURCES.md`.
