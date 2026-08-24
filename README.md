# TITAN patient-level prediction benchmark and model resource

Reproducible, patient-level prediction of molecular, immune and genomic
features from fixed pretrained TITAN whole-slide embeddings across 32 TCGA cancer
types.

This project is positioned as a systematic benchmark and reusable fitted-model
resource, not as the first pan-cancer histology-to-molecular screen. In
particular, Arslan et al. previously trained 12,093 models for 4,031 biomarkers
in 8,890 TCGA patients across the same 32 cancers. The machine-readable
comparison with Fu, Kather, Saldanha, Arslan and the present study is
[`data/reference/pan_cancer_benchmark_comparison.csv`](data/reference/pan_cancer_benchmark_comparison.csv).

Public repository: https://github.com/tkcaccia/titan-prediction

Access-controlled fitted-model R package: https://github.com/tkcaccia/TITANPred

The TITANPred repository is currently private. The public analysis repository
therefore does not claim that fitted-model artifacts are openly downloadable;
release remains subject to upstream redistribution permission and an explicit
versioned release decision.

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
10 oversampling vectors, two power iterations and explicit seeds. Repeated
nested validation and exact solver metadata are retained.

## Multiple slides per patient

The patient is the analysis unit. All eligible primary-tumour diagnostic
slides (`01`, `DX`) for a participant are averaged feature-by-feature before
model fitting. This deterministic mean-pooling rule uses no outcome data,
keeps every participant in exactly one validation fold and avoids the
arbitrary choice of a first slide. Slide-level and case-level report text is
used only to audit slide provenance and is never supplied to a predictor.

## Reproducibility

### Obtain and convert the official TITAN TCGA features

The whole-slide input was downloaded from the gated
[`MahmoodLab/TITAN`](https://huggingface.co/MahmoodLab/TITAN) repository as
[`TCGA_TITAN_features.pkl`](https://huggingface.co/MahmoodLab/TITAN/blob/main/TCGA_TITAN_features.pkl).
After accepting the upstream non-commercial research terms, convert the
official pickle to the exact CSV schema used by this project with:

```bash
export HF_TOKEN="your_read_token"
python3 tools/convert_tcga_titan_pickle.py \
  --download \
  --input data/raw/TCGA_TITAN_features.pkl \
  --output data/raw/TCGA_TITAN_features.csv \
  --acknowledge-trusted-pickle
```

Only load a pickle obtained from the official repository: Python pickle is an
executable format. The converter validates 768 finite numeric values per slide
and writes a sidecar containing the source and CSV SHA-256 hashes. The supplied
analysis CSV contains 11,658 slide rows and has SHA-256
`d3d91fb0f83a6de440eda5ff437a63e3ca13f50095e6841fb8efcc40e58763f0`.

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
fitted object retains the patient-level diagnostic arrays removed for research
use. Robustness checkpoints are reused only when a fingerprint of the
final screens, configuration, cohort schema/source, fastPLS build and backend
matches the current run; obsolete checkpoint files are not collated.

During a long permutation run, `Rscript tools/permutation_progress.R` reports
read-only checkpoint counts and attempted permutations without changing state.

### Exploratory histology-context models

`Rscript R/12_histology_context_models.R` runs three patient-level analyses
that are kept separate from the primary molecular and inflammatory benchmark:

- a 32-class TCGA cancer-type PLS-LDA model (9,395 participants; nested-CV
  accuracy 0.881 and macro-recall 0.826);
- cancer-specific PLS1 models for the consensus purity estimate (CPE) published
  by Aran, Sirota and Butte (Nature Communications 2015,
  doi:10.1038/ncomms9971); and
- a deliberately non-releaseable KICH tumour-versus-adjacent-normal pilot using
  only 12 matched participants.

These are internal TCGA screening results, not externally validated clinical
classifiers. The KICH pilot is retained to document why the available normal
set is insufficient. Cancer-type and purity fitted artifacts in
`models/histology_context/` contain feature definitions and coefficients but
exclude patient-level training scores and outcomes. The script requires the
published CPE spreadsheet at the path documented in its source and is therefore
not called by the main benchmark runner.

This produces the main manuscript, Additional file 1 (supplementary methods,
tables and figures), the point-by-point reviewer response, and two separate
single-sample PDF reports designated as Additional files 2 and 3 under
`manuscript/`. Numerical statements and tables are read directly from released
CSV files; they are not separately hand-entered.

Large source datasets and TITAN embeddings are not redistributed here.
`R/00_download_cbioportal.R` retrieves public MSI clinical fields from the
cBioPortal Datahub and records URLs and SHA-256 digests. Screening tables
record endpoint family, cancer type, eligibility counts, validation seed,
software version and backend; source-specific audit tables retain their
relevant denominator and aggregation fields. `software_manifest.csv` records
package versions and the pinned fastPLS and TCGAmutations GitHub source
commits.

## Applying cancer-matched models in research software

All 323 fitted research models are maintained in the separate, currently
private [`TITANPred`](https://github.com/tkcaccia/TITANPred) R package. They are
not presented as externally validated or publicly released predictors. An
authorised research user supplies a
cancer vector and correctly named TITAN features; `predict_titan()` applies
every model available for each cancer and returns a long patient-model table.
Repeated patient identifiers are mean-pooled before inference.

```r
remotes::install_github("tkcaccia/TITANPred", dependencies = TRUE)
library(TITANPred)

predictions <- predict_titan(
  cancer = my_cancer_vector,
  features = my_titan_features,
  patient_id = my_patient_ids
)
```

`titan_sample_report()` generates a research-software HTML or PDF demonstration with a
continuous-endpoint radar, binary PLS-LDA calls, exact reference percentiles and
original internally derived TCGA estimates, out-of-distribution diagnostics,
and research-use provenance.
All endpoint definitions and model-target sources are documented at the end of
the report. Optional pathology or treatment context is displayed separately and
is never passed to the model. Reproducible matched COAD examples generated for
Figure 7 are available under [`results/reports`](results/reports/).

Every inference row reports the TCGA tissue-source-site-grouped internal metric,
grouped-minus-random change, analysed-site count, threshold-retention status and
warning. Models that become near chance or fall below their original effect
threshold are labelled prominently rather than highlighted without qualification.

Every bundled RDS object includes the exact 768-column feature order, slide
aggregation rule, cancer type, endpoint, selected component count, class counts
and priors where applicable, endpoint transformation and output units, exact
fastPLS version and Git commit, computation backend, and research-only
intended-use statement. The analysis repository records SHA-256 hashes for all
artifacts. The public [`models/model_registry.csv`](models/model_registry.csv)
also records the grouped metric, delta, number of sites, fold-size range, inner
site-separation audit and site-robustness warning for all 323 models. The objects
contain no patient-level training rows.

PLS and PLS–LDA are parametric models: external prediction needs the learned
preprocessing values, latent weights, coefficients and classification
parameters, but not the patient-level training embeddings or outcomes. This
minimises the patient-level research data that must be exchanged; it is not a
guarantee of privacy or transportability.

## Intended use

Research use only. The models are internally validated retrospective TCGA
research models, not medical devices and not suitable for patient care.

## Tissue-source-site sensitivity

Tissue-source-site sensitivity is a principal result. Under grouped internal
validation, 83/323 screen-positive models (25.7%) fell below their original
effect threshold. Complete target-level performance is provided in
[`results/tables/site_grouped_models_below_effect_threshold.csv`](results/tables/site_grouped_models_below_effect_threshold.csv),
and all 1,613 outer-fold patient, site and binary class counts are in
[`results/tables/site_grouped_outer_fold_composition.csv`](results/tables/site_grouped_outer_fold_composition.csv).
The deterministic audit confirms that complete sites were kept together during
both outer evaluation and inner component selection.

A dedicated repeated nested PLS–LDA analysis predicted tissue-source site from
TITAN representations within 27/32 cancers after requiring at least 10 patients
per analysed site. Results are in
[`results/tables/tissue_source_site_predictability_summary.csv`](results/tables/tissue_source_site_predictability_summary.csv).
This quantifies confounding potential; tissue-source site remains an imperfect
proxy for institution, scanner, laboratory and staining batch.

## Symmetric PLS–ridge benchmark

The secondary comparison of 12 highlighted binary models now uses identical
outer folds, identical inner folds and the same decision rule for both methods:
within each outer training set, PLS–LDA and ridge operating thresholds are
selected from inner out-of-fold scores to maximise balanced accuracy. AUROC is
the threshold-independent primary binary comparison metric; the symmetrically
thresholded balanced accuracy is reported alongside it. The prespecified atlas
continues to use its original fitted PLS–LDA class rule and is not altered by
this conditional benchmark. Repeat-level results are in
[`results/tables/binary_symmetric_pls_ridge_repeated_nested_cv.csv`](results/tables/binary_symmetric_pls_ridge_repeated_nested_cv.csv),
with model-level comparisons in
[`results/tables/pls_vs_ridge_highlighted_models.csv`](results/tables/pls_vs_ridge_highlighted_models.csv).

## Independent evaluation status

No independent cohort has been evaluated. TCGA resampling and the explicitly
named "TCGA tissue-source-site-grouped internal validation" remain internal
analyses and cannot establish scanner- or institution-level transportability.
A future untouched evaluation has been
locked to three UCEC artifacts—TP53 mutation, genome doubling and continuous
aneuploidy score—with no refitting, recalibration or threshold adjustment. The
complete protocol is in
[`docs/EXTERNAL_VALIDATION_PROTOCOL.md`](docs/EXTERNAL_VALIDATION_PROTOCOL.md),
and the exact model hashes and metrics are in
[`data/reference/external_validation_locked_targets.csv`](data/reference/external_validation_locked_targets.csv).

CPTAC-UCEC is a plausible cohort because its official TCIA collection links
pathology and molecular resources, but compatible precomputed TITAN embeddings
were not identified. No external performance claim will be made unless the
locked analysis is completed and every target, including failures, is reported.

## License and attribution

Repository code is released under GPL-3.0 because `fastPLS` is GPL-3.0.
Source data retain their respective upstream terms. The analysis code and
TITANPred package are GPL-3.0 licensed; see `provenance/SOURCES.md` for source
attribution.
