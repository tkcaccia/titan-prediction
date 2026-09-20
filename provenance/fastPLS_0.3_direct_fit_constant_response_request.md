# fastPLS 0.3 request: direct regression fit must support zero effective directions

## Environment

- fastPLS version: 0.3
- GitHub commit: `8b9d03eb3274801e4c59209ff19d640b198c9ade`
- Backend: CPU
- Decomposition: rSVD
- rSVD controls: fastPLS defaults; no oversampling or power arguments are
  supplied by the reproduction

The TITAN project will use the default rSVD controls supplied by the installed
fastPLS version. The analysis should not override the package defaults for
oversampling or power. The defect below reproduces with those defaults and is
not a request to change them.

## Blocking behaviour

The corrected cross-validation path handles constant-response folds, but the
direct regression fit called after component selection does not. When the
training response is constant and one component is requested,
`fastPLS::pls()` stops with:

```text
fastPLS core SIMPLS returned fewer components than requested
```

This makes nested cross-validation internally inconsistent. The inner
`pls.single.cv()` call accepts the same constant-response training data and
selects `best_ncomp = 1`, but the subsequent direct `pls(..., ncomp = 1)` fit
fails because the effective number of response-associated directions is zero.

The immediate throw is in
`src/r_api.cpp` around line 1479 in commit `8b9d03e`, inside
`fit_simpls_core_prepared()`, where
`model.completed_components < controls.components` is treated as an
unconditional error. The cross-validation code now handles this state, but the
direct-fit serializer/API path does not yet implement the corresponding
intercept-only or truncated-path result.

## Minimal reproduction

```r
library(fastPLS)
set.seed(1)
X <- matrix(rnorm(41 * 768), nrow = 41, ncol = 768)
y <- rep(0, 41)

fastPLS::pls(
  X, y,
  ncomp = 1,
  fit = TRUE,
  return_loadings = TRUE,
  seed = 20261542
)
```

Observed result:

```text
Error in fit_core(...):
  fastPLS core SIMPLS returned fewer components than requested
```

The project-data reproduction is:

```bash
cd /Users/stefano/Documents/Titan/titan-prediction
Rscript tools/reproduce_fastpls_0.3_simpls_shortfall.R
```

It identifies:

- representation: TITAN
- cancer: ACC
- endpoint: T Cells CD4 Memory Activated
- matched-atlas job: 625
- endpoint sample size: 52
- outer fold: 2
- outer-training size: 41
- outer-test size: 11
- outer-training response SD: exactly 0
- inner result: `best_ncomp = 1`
- failure: subsequent direct `fastPLS::pls()` fit

This is not limited to one endpoint. Six of 1,933 matched continuous tasks are
blocked, and each contains exactly one constant-response outer-training fold
under the fixed partitions:

| Job | Cancer | Endpoint | n |
|---:|:---|:---|---:|
| 625 | ACC | T Cells CD4 Memory Activated | 52 |
| 826 | ESCA | T Cells gamma delta | 143 |
| 960 | KICH | T Cells CD4 Memory Activated | 65 |
| 1202 | LUAD | T Cells CD4 Naive | 410 |
| 1708 | TGCT | Eosinophils | 148 |
| 1834 | THYM | T Cells gamma delta | 113 |

The other 1,927 matched tasks completed, including the separately rerun final
UCS task that had only been cancelled when the parallel worker batch stopped.

## Requested behaviour

For regression with zero estimable PLS directions, the direct-fit API should
return a valid intercept-only model rather than stop.

1. Record `requested_components = 1` and `effective_components = 0` in model
   diagnostics.
2. Store the complete requested prediction path. For every requested prefix,
   fitted and new-data predictions should equal the training-response mean.
3. Store zero regression coefficients for every requested prefix.
4. Return `NA` for response-variance metrics whose denominator is zero, rather
   than manufacturing an effect or raising an error.
5. Make `predict()` work for arbitrary new rows and return the training mean
   with the usual output dimensions.
6. If loadings or scores have no estimable direction, return documented empty
   structures or compatible zero-column matrices while keeping prediction and
   coefficient paths usable.
7. Apply the same safe path whenever the core returns fewer effective
   components than requested: clamp to the available directions and repeat the
   last estimable prediction and coefficient path. When zero directions are
   available, repeat the intercept-only path.

The direct-fit behaviour should match the already corrected cross-validation
behaviour. No analysis-side fallback and no change to the fastPLS default rSVD
parameters should be required.

## Required tests

- Constant response with `ncomp = 1` and `ncomp = 1:10`.
- Exactly zero response and a non-zero constant response.
- `center`, `autoscale`, and `none` scaling modes.
- Wide and tall predictor matrices.
- Fixed-seed determinism.
- All tests should use the fastPLS default rSVD controls unless a test is
  specifically designed to examine explicit control overrides.
- Finite fitted and new-data predictions.
- Prediction equals the training-response mean.
- Complete requested prediction and coefficient paths.
- Diagnostics report zero effective directions.
- A nested-CV test in which an outer-training response becomes constant even
  though the full response is not constant.

The full atlas run should be restarted only after this direct-fit case passes.
