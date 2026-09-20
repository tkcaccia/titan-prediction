# Documented analysis plan and chronology

This plan first appears in repository commit
`bb0ccb8d016072519913d8a78e0157b9f2e09c5f` dated 15 August 2026. That
initial repository snapshot also contains completed outcome results. Git
history therefore verifies that the plan was documented in the initial
snapshot, but it does **not** independently verify that any primary rule was
locked before result inspection. The study was not prospectively registered.
The manuscript consequently calls the thresholds, eligibility limits,
component range and local FDR scheme “documented analysis rules in the initial
repository snapshot.”

Later analyses are labelled secondary, sensitivity, post hoc or revision-added
according to `data/reference/analysis_chronology.csv`. The eight-target
high-resolution permutation refinement is separately auditable: its target
registry was committed in `ac30ccb` before the 9,999-permutation results were
generated. The future external-validation protocol was locked before any
external evaluation, but no external result currently exists.

The revision-added fold-assignment audit of the three-representation atlas was
fixed before its alternative-partition results were inspected. It includes
every primary-partition union-positive cancer–endpoint pair and every pair for
which at least one representation lay within ±0.05 of Q²=0.20 (continuous) or
balanced accuracy=0.60 (binary). Five new nested 5×5 partitions are generated
per selected task. Each partition, outcome-labelled patient set, seed and
tuning rule is identical across TITAN, Giga-SSL and Prov-GigaPath. These are
alternative partitions, not repeats of the primary partition and not an
independent cohort.

## Catalogue-normalized breadth

The matched benchmark contains 1,933 cancer–endpoint tasks but 187 exact
endpoint definitions (56 continuous and 131 binary). Because endpoints are
correlated and repeatedly evaluated across cancers, a crossing count is a
catalogue-level breadth measure rather than a count of independent biological
signals. For each representation and outcome type we therefore report: (1) the
task crossing percentage; (2) the percentage of exact family–endpoint–source
definitions crossing in at least one cancer; (3) the unweighted mean of
within-family crossing percentages; and (4) the unweighted mean of within-cancer
crossing percentages. We additionally count the eligible and retained cancers
for every exact endpoint definition and endpoint-dictionary biological
programme. These revision-added summaries are descriptive and do not add
permutation or multiplicity qualification to the three-representation atlas.

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
- Binary target: one-target PLS followed by LDA within each cancer type. The
  documented atlas rule uses observed outer-training-fold class priors. A
  revision-added complete sensitivity compares that rule on identical outer
  partitions with equal LDA priors and a threshold selected from pooled inner
  held-out scores to maximise balanced accuracy; component count is reselected
  inside each outer training set under each alternative rule.
- Immune multivariate sensitivity: PLS2, evaluated only on complete matched
  samples and identical folds; comparison is secondary.

Component number (1-20) is selected inside the training portion of every
outer fold. Performance is calculated exclusively from out-of-fold patient
predictions. Balanced accuracy is primary for binary outcomes; AUROC from
continuous LDA scores is secondary. Q-squared is primary for continuous
outcomes. Every primary, permutation, repeated, sensitivity and final-model PLS
fit uses CPU rSVD exclusively, with the fastPLS 0.3 defaults of 32
oversampling vectors and five power iterations plus an explicit fit seed.
Repeated nested
validation therefore reflects both partition and rSVD-seed variation.

The five inner-fold held-out predictions are pooled before calculating the
tuning objective. Exact component-count ties choose the smallest count. For
the optimized binary rule, every observed unique inner score plus the two
constant-class extremes is considered; exact threshold ties prefer a finite
value and then the value nearest zero. No outer-test label is used for
component or threshold selection. AUROC and PR-AUC remain score-based metrics;
this sensitivity is not probability calibration, and newly gained crossings
do not inherit permutation/FDR qualification from the documented rule.

Thorsson Nonsilent Mutation Rate, Silent Mutation Rate, SNV Neoantigens,
Indel Neoantigens and Number of Segments, together with Gao fusion burden,
are analysed as `log1p(x)`. Other continuous outcomes remain in source units;
reported RMSE follows the analysed scale.

The pathway activity layer uses the UCSC Xena TCGA Pan-Cancer normalized
RNA-seq matrix and the versioned MSigDB 2026.1.Hs definitions for all 50
Hallmarks, Reactome glutathione synthesis and recycling, and Gene Ontology
vitamin B6 metabolism. Only primary-tumour RNA samples are retained. Multiple
RNA aliquots are averaged by participant before scoring. Within each cancer,
each measured member gene is standardized across participants and each pathway
score is the mean of its available member-gene z scores. These targets measure
agreement with RNA-derived pathway activity and are not direct metabolite,
protein, enzymatic-flux or clinical-assay measurements.

## Eligibility and multiplicity

Continuous cancer-target pairs require at least 50 non-missing patients.
Binary pairs require at least 20 positive and 20 negative patients. All
eligible pairs remain in multiplicity correction. Because each cancer defines
a separate prediction screen and model-use population, primary Benjamini–
Hochberg control is calculated separately for continuous and binary outcomes
within cancer and documented endpoint family. A stricter q-value across all
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

The completed-test minimum p-value is 0.001. This supports the documented
within-cancer screens but limits attainable q-values for large across-cancer
families. The global family correction is therefore a deliberately strict,
resolution-limited sensitivity analysis; non-passage is not interpreted as
evidence that an endpoint contains no biological signal.

## Participant characteristics

The TCGA Clinical Data Resource is linked by participant barcode for
descriptive reporting only. Age, source-recorded gender and race, and broad
stage are summarized overall and by cancer with their missingness. These
variables are not supplied to a predictor. No demographic subgroup model
comparison was part of the documented original analysis because molecular
coverage and subgroup sizes vary substantially across the cancer-specific
endpoint screens.

## Robustness

Within-cancer screen-positive models are repeated across five independently
seeded nested 5x5 cross-validations. TCGA tissue-source-site-code grouped
validation and pooling sensitivities are reported separately. Pooling analyses
compare the documented arithmetic mean with a coordinate-wise median and the
lexicographically first eligible slide using the same patients, seeds, rSVD
settings and nested-CV rules. Pairwise slide cosine dispersion,
mean-versus-median centroid distance and maximum leave-one-slide-out centroid
change quantify embedding heterogeneity for all three released representations.
The 30-slide SARC participant is removed before fold construction in an
additional refit of all SARC candidates. No pathology-report text is used as a
predictor.

Generated no-residual-tumour narrative mentions are audited at both slide and
patient level and remain explicitly non-adjudicated. As a retrospective
sensitivity analysis, every patient carrying such a flag is removed before
fold construction and all screen-positive models in the affected cancers are
refitted. This analysis does not redefine primary slide eligibility, supply a
pathology label or replace independent slide review.

Molecular–slide linkage is audited by source using the 15-character TCGA sample
barcode whenever the molecular table supplies one. The Thorsson PanImmune table
is participant-indexed only. Even exact sample-barcode agreement is interpreted
as specimen-level linkage, not proof of a common tissue portion, analyte,
aliquot, block, tumour region or subclone.

For the central matched representation benchmark, fold-assignment stability is
reported for all union-positive and near-threshold tasks. Outputs retain the
continuous Q²/AUROC effect estimates, empirical-prior balanced-accuracy
crossing status, selected components and fold hashes for every representation
and repeat. Per-task crossing proportions and the stability of the descriptive
classes “all three”, “exactly two”, “representation specific” and “none” are
reported alongside continuous paired effects and ranks. Threshold-sensitivity
curves cover Q² from 0.10 to 0.30 and balanced accuracy from 0.55 to 0.65.
Categorical crossing labels are therefore not treated as invariant biological
properties.

For every one of the 340 primary union-positive matched tasks, a revision-added
cohort-structure sensitivity keeps complete two-character TCGA tissue-source-site
codes together in both outer and inner validation. TITAN, Giga-SSL and
Prov-GigaPath use identical task-specific patients, grouped folds, seeds and tuning
rules. A matched-random control has identical outer-fold sizes and, for binary
outcomes, identical positive/negative counts. The primary comparison is retention
of each representation's original Q²≥0.20 or balanced-accuracy≥0.60 crossing;
grouped-minus-matched-random Q² (continuous) or AUROC (binary) is also reported.

An internal prioritisation class combines three dimensions: representation
consensus, sample-size maturity (continuous n≥100; binary both classes≥50), and
retention of the originally crossing representations after grouping. R1 denotes
all-three/mature/complete retention; R2 at least two/mature/complete retention; R3
mature with at least one retained crossing but not R1/R2; R4 limited sample-size
maturity or no retained crossing. These revision-added labels are not clinical
grades, inferential discoveries, proof of confounding, or external validation.

The maturity cut-offs are revision-added evidence descriptors rather than
retrospective significance filters. Inclusive and standard-evidence counts are
reported in parallel; the descriptor does not alter task eligibility, effect
thresholds, raw p-values, BH denominators, q-values or the complete atlas.

For the TITAN permutation/FDR layer, every eligible model below the performance
checkpoint is assigned raw p=1 without permutation. This is recorded separately
from a checkpoint-passing test that starts permutation but is conservatively
early-stopped after 49 exceedances and assigned raw p=1. Every eligible row in
both categories remains in all applicable local, across-cancer/family,
outcome-wide and atlas-wide BH denominators.

## Endpoint provenance and qualitative morphology context

Every eligible cancer–endpoint test is assigned one of six label-generation
classes: directly observed genomic alteration, sequencing-derived continuous
burden, computationally inferred immune-cell fraction, transcriptomic
signature, pathology-associated quantity or composite genomic-context score.
The target-level dictionary retains source modality, direct/inferred status,
derivation algorithm, source scale, transformation, missingness, expected
measurement error, interpretation and assay-equivalence caveat. TIL Regional
Fraction is flagged as a same-H&E-modality target.

The revision-added matched-atlas provenance analysis reports crossings
separately for directly observed genomic alterations, sequencing-derived
continuous burdens, computationally inferred immune-cell fractions,
transcriptomic signatures, composite genomic-context scores and
pathology-associated quantities. It also recalculates continuous and total
crossing counts after excluding same-H&E tasks. Strong translational examples
must be mature, cross in all three representations and retain the threshold for
all three when TCGA tissue-source-site codes are held apart; they are ranked
within provenance class by the minimum primary effect across representations.
This is a revision-added descriptive analysis, not a multiplicity-controlled
discovery layer.

Morphological context is descriptive and secondary. Five representative label
modalities are illustrated with concordant high/low anchors from repeated
out-of-fold predictions and their nearest within-cancer patient-level mean
TITAN neighbour by cosine similarity. A report-covered slide closest to each
patient mean supplies a deterministic identifier and automated report context.
Report text does not enter fitting. Because only global pooled embeddings and
TITAN-generated same-slide reports are available, this analysis is not
patch-level relevance, causal attribution or blinded pathologist review.
