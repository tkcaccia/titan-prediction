# Request to make grouped PLS-LDA component paths robust in fastPLS 0.3

## Summary

Please extend the recent degenerate-fold fix in fastPLS 0.3 to the PLS-LDA
classification path. Regression cross-validation now handles folds with fewer
effective PLS directions than requested, but PLS-LDA still stops when the LDA
prefix list contains a component count larger than the score matrix produced
inside a fold.

This affects both `pls.single.cv()` and `pls.double.cv()` with
`classifier = "lda"`. It occurs in grouped validation when a small or
imbalanced training fold has lower effective rank than the requested component
grid.

## Validated environment

- fastPLS version: 0.3
- Git commit: `a3430f45a515df9901bd4b4305dbb31f64013a24`
- Backend: CPU
- BLAS: Apple Accelerate
- Method: SIMPLS with native randomized SVD
- rSVD controls: 10 oversampling vectors and two power iterations

## Error

```text
fastPLS LDA component counts must be within the score dimension
```

The exception is raised by the LDA prefix validation in
`src/r_api.cpp` and `inst/include/fastpls/core/lda.hpp`. The R-level sequential
component cap uses the predictor matrix rank bound, but an inner fold can
produce fewer actual PLS score columns than that bound. The requested prefix
list is then passed unchanged to the compiled LDA trainer.

## Self-contained reproduction

The complete script is
`tools/reproduce_fastpls_0.3_lda_component_path_error.R`. It uses only
synthetic data and can be run from the project root:

```sh
Rscript tools/reproduce_fastpls_0.3_lda_component_path_error.R
```

The essential example is:

```r
library(fastPLS)

set.seed(1L)
X <- matrix(rnorm(53L * 768L), nrow = 53L, ncol = 768L)
y <- factor(
  c(rep(0L, 30L), rep(1L, 18L), 1L, 0L, 0L, 0L, 1L),
  levels = c(0L, 1L)
)
group <- c(rep("OR", 48L), "OU", "PA", rep("PK", 3L))

fastPLS::pls.single.cv(
  X, y,
  ncomp = 1:10,
  constrain = group,
  kfold = 5L,
  classifier = "lda",
  selection = "balanced_accuracy",
  scaling = "centering",
  backend = "cpu",
  oversample = 10L,
  power = 2L,
  seed = 20262901L,
  fit = FALSE
)
```

In this synthetic example, `ncomp = 1:4` completes and `ncomp = 1:5` fails.
The full `1:10` path also fails. With the same data and settings,
`pls.double.cv()` completes for `ncomp = 1` and fails for `ncomp = 1:4` or
`1:10` because an outer training split has a still lower effective score
dimension.

The project-data trigger is ACC, oncogenic pathway WNT. It contains 53
patients, 33 negative and 20 positive, distributed across four TCGA
tissue-source-site codes. One grouped outer split leaves five training
patients. In the corresponding grouped inner validation, only one PLS
direction is estimable. `ncomp = 1` succeeds, while any path containing
component 2 fails.

## Required behavior

The public cross-validation API should accept a requested component path that
extends beyond the number of directions estimable in one or more folds.
Behavior should be consistent with the repaired regression path.

For every inner or outer fit:

1. Determine the effective number of PLS score columns actually produced.
2. Train LDA only for prefixes from one through that effective count.
3. For each larger requested prefix, reuse the LDA prediction, discriminant
   score, and validation metric from the last estimable prefix.
4. Preserve every requested component value in the returned tuning path.
5. Record the requested and effective component count so the truncation is
   auditable.
6. Apply the existing deterministic tie rule to duplicated metrics. Prefer the
   lowest requested component count among tied values.
7. Return finite predictions and scores whenever both response classes are
   represented in the fold.

If zero PLS directions are estimable, implement and document a deterministic
class-only fallback. A reasonable empirical-prior rule is to use the training
class priors for class calls and finite log-prior contrasts for scores. If
equal priors are requested, define a deterministic tie rule. The returned
object should identify that zero-direction fallback explicitly.

If an inner or outer training fold contains only one response class, do not
allow a low-level matrix-dimension exception. Either return a documented
single-class fallback or a specific high-level condition containing the fold,
class counts, and requested component path.

## Required tests

Please add automated tests covering both `pls.single.cv()` and
`pls.double.cv()` for:

- grouped binary folds with one effective score direction;
- requested paths `1`, `1:2`, and `1:10`;
- a path extending beyond the predictor-rank cap;
- centering, autoscaling, and no scaling;
- empirical and equal LDA priors if both are supported;
- fixed-seed determinism;
- finite class predictions and discriminant scores;
- retention of every requested prefix in the tuning results;
- repetition of the last estimable predictions and metrics for unavailable
  prefixes;
- zero-direction binary folds;
- single-class inner and outer training folds;
- sparse class counts and highly unbalanced groups;
- CPU behavior and any enabled accelerated backend;
- no regression in balanced accuracy, sensitivity, specificity, AUROC, and
  precision-recall AUC calculations.

The synthetic reproduction above should become a regression test. The test
should fail on commit `a3430f45a515df9901bd4b4305dbb31f64013a24` and pass on
the corrected release.

## Acceptance criteria for the atlas rerun

The pathology atlas will restart from raw inputs only after a new fastPLS
commit satisfies all of the following:

- the existing degenerate-regression tests still pass;
- the new synthetic grouped PLS-LDA reproducer completes for `ncomp = 1:10`;
- the full requested tuning path is retained;
- outputs are finite and deterministic under the fixed seed;
- the exact ACC-WNT grouped analysis completes without a project-side
  component-grid fallback;
- `R CMD check --as-cran` reports no errors or warnings.

No result from the interrupted diagnostic atlas run will be accepted into the
manuscript, figures, tables, model registry, or PathoFMPred release.
