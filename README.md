# TITAN prediction atlas

Reproducible, patient-level prediction of molecular, immune and genomic
features from fixed pretrained TITAN whole-slide embeddings across 32 TCGA cancer
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

Participant age, recorded gender, race and broad stage are summarized overall
and by cancer from the TCGA Clinical Data Resource. These descriptors document
cohort composition; they are not used as predictors and do not substitute for
subgroup performance or fairness evaluation.

Mutation and other binary endpoints use PLS latent variables followed by LDA;
continuous endpoints use PLS1 regression. The matched PLS1-versus-PLS2
comparison for coherent inflammatory blocks is secondary and is reported in
the supplementary material. All reported fits use CPU rSVD exclusively, with
10 oversampling vectors, two power iterations and explicit seeds. IRLBA is not
used. Because rSVD is stochastic, repeated nested validation and exact solver
metadata are retained; no speed or algorithmic-superiority claim is made.

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

The primary inferential screen refines every effect-qualified endpoint to a target of
999 patient-label permutations, with conservative sequential stopping at the
point where raw p<0.05 is impossible. It controls FDR separately by outcome
type within cancer and endpoint family and also writes a stricter across-cancer
q-value within the same outcome type and family. Set
`TITAN_RUN_999=false` only for a non-final pilot run. The pipeline records the
actual number attempted, stopping status, `fastPLS` version and computational
backend so that the analysis environment can be reconstructed. The minimum
completed-test p-value is 0.001; consequently, the across-cancer correction is
a deliberately strict, resolution-limited sensitivity analysis for large
endpoint families, and non-passage is not treated as evidence of no signal.

After the R pipeline finishes, build the submission documents with:

```bash
python3 manuscript/build_documents.py
```

After generating the fresh reviewer report, run
`python3 tools/audit_documents.py`. This enforces the exact four-file DOCX
package, current author/correspondence block, abstract and keyword limits,
required sections, and embedded-figure inventory before page-by-page rendering.

Before release, run `Rscript tools/audit_release.R`. This fails if the final
permutation state is incomplete, endpoint keys are duplicated, repeated
out-of-fold coverage is missing, sensitivity analyses omit a highlighted
screen-positive model, artifact hashes or analysis fingerprints differ, or a
fitted object retains the patient-level diagnostic arrays removed for
deployment. Robustness checkpoints are reused only when a fingerprint of the
final screens, configuration, cohort schema/source, fastPLS build and backend
matches the current run; obsolete checkpoint files are not collated.

During a long permutation run, `Rscript tools/permutation_progress.R` reports
read-only checkpoint counts and attempted permutations without changing state.

This produces the main manuscript, supplementary material and point-by-point
reviewer response under `manuscript/`. Numerical statements and tables are read
directly from released CSV files; they are not separately hand-entered.

Large source datasets and TITAN embeddings are not redistributed here.
`R/00_download_cbioportal.R` retrieves public MSI clinical fields from the
cBioPortal Datahub and records URLs and SHA-256 digests. Screening tables
record endpoint family, cancer type, eligibility counts, validation seed,
software version and backend; source-specific audit tables retain their
relevant denominator and aggregation fields. `software_manifest.csv` records
package versions and the pinned fastPLS and TCGAmutations GitHub source
commits.

## Deploying a fitted model

See `examples/predict_titan_features.R`. The example accepts one or more
TITAN slide embeddings per patient, validates all 768 dimensions, applies
the same mean pooling used during training, and returns patient-level
predictions.
Returned data frames carry `model_id`, `endpoint_transform` and `output_units`
attributes so transformed continuous outputs cannot be mistaken for source-scale
values.

Every exported RDS object includes the exact 768-column feature order, slide
aggregation rule, cancer type, endpoint, selected component count, class counts
and priors where applicable, endpoint transformation and output units, exact
fastPLS version and Git commit, computation backend, and research-only
intended-use statement.

PLS and PLS–LDA are parametric models: external prediction needs the learned
preprocessing values, latent weights, coefficients and classification
parameters, but not the patient-level training embeddings or outcomes. This
supports model sharing while minimising distribution of patient-level research
data; it is not a guarantee of privacy, transportability or redistribution
permission.

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
