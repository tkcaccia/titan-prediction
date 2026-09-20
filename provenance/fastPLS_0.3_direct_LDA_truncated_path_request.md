# fastPLS 0.3 correction request: direct PLS-LDA truncates requested paths

## Decision for the pathology atlas

The atlas rerun has been stopped. The new fastPLS build passes the previously
reported regression and grouped cross-validation acceptance tests, but a new
blocking inconsistency remains in the direct fitted PLS-LDA prediction path.
Three tissue-source-site-code grouped binary tasks cannot be evaluated because
the project requests components 1 through 10 and direct prediction returns only
the estimable prefixes.

## Validated environment

- fastPLS version: 0.3
- Installed GitHub commit: `35c78a146abae35ba132bd2c1822e39ba8eb6cc1`
- Backend used by the atlas: CPU
- BLAS reported by `fastPLS_blas()`: Apple Accelerate
- `has_metal()`: `FALSE`
- `has_cuda()`: `FALSE`
- rSVD parameters: fastPLS defaults, with no `rsvd_oversample` or
  `rsvd_power` override in the reproducer

## Observed behavior

For a direct classification fit such as:

```r
fit <- fastPLS::pls(
  X, y,
  ncomp = 1:10,
  classifier = "lda",
  fit = TRUE,
  return_loadings = FALSE,
  seed = 77L
)
prediction <- predict(fit, Xnew, raw_scores = TRUE)
```

when the effective rank is eight, fastPLS warns:

```text
The component path is limited to rank 8; requests above this value are capped at 8 internally.
```

However, the returned objects do not retain the requested ten-prefix path:

```text
fit$effective_ncomp: 1,2,3,4,5,6,7,8
dim(prediction$LDA_scores): 3 x 2 x 8
dim(prediction$Ypred): 3 x 8
```

The warning says that requests above eight are capped, but outputs for requested
components nine and ten are absent. This differs from the corrected
`pls.single.cv()` and `pls.double.cv()` behavior, which retains all requested
prefixes and repeats the last estimable prediction.

In the atlas, the missing prefixes lead the AUROC-tuning helper to index a
nonexistent score slice:

```text
Error in scores[, 2L, component_index] : subscript out of bounds
Calls: fit_on_outer ... fit_binary_nested_auroc_once ->
       select_binary_auroc_rule -> binary_score_contrast
```

The affected grouped tasks in the current run are:

- ACC, genome doubling
- OV, TP53 mutation
- UVM, GNA11 mutation

For OV-TP53, one grouped training partition estimates only eight directions and
triggers the warning and indexing failure above.

## Self-contained reproduction

Run from the `titan-prediction` project root:

```sh
Rscript tools/reproduce_fastpls_0.3_direct_lda_truncated_path.R
```

The reproducer uses only a 9 by 20 synthetic matrix and the fastPLS defaults.
It currently fails its final acceptance assertions after printing the eight
returned prefixes.

## Requested correction

Please make direct `pls(..., classifier = "lda", fit = TRUE)` and its
`predict(..., raw_scores = TRUE)` method follow the same requested-path
contract as the corrected cross-validation APIs.

For a requested path that exceeds the effective rank:

1. Preserve one output position for every requested component value.
2. Report `effective_ncomp` aligned to the requested path. For `1:10` with
   effective rank eight, return `1,2,3,4,5,6,7,8,8,8`.
3. Repeat the last estimable class prediction and LDA score for requests nine
   and ten.
4. Preserve or add the requested component labels in the third dimension of
   `LDA_scores` and the component dimension of `Ypred`.
5. Expose both requested and effective component counts explicitly so callers
   do not have to infer truncation from array dimensions.
6. Keep the current informative warning, but state that the returned path has
   been padded by repeating the last estimable prefix.
7. Apply the same behavior under centering, autoscaling and no scaling, and for
   empirical and equal LDA priors.
8. Define equivalent deterministic behavior when zero directions are
   estimable, including finite scores and an explicit fallback indicator.

## Required regression tests

Please add tests for direct fitted PLS-LDA and prediction that cover:

- requested paths `1`, `1:8`, and `1:10` when rank is eight;
- exact retention of every requested prefix;
- equality of predictions and scores for capped prefixes;
- aligned requested and effective component metadata;
- finite results and fixed-seed determinism;
- all supported scaling modes and LDA-prior settings;
- zero-direction and single-class edge cases with documented high-level
  behavior;
- CPU and any enabled accelerated backend;
- no regression in the already passing `pls.single.cv()` and
  `pls.double.cv()` grouped-component-path tests.

## Acceptance gate before restarting the atlas

The atlas will restart from the beginning only after:

- the self-contained reproducer passes unchanged;
- the previous regression and grouped PLS-LDA cross-validation reproducers
  still pass;
- the three affected grouped atlas tasks complete without a project-side
  component-grid workaround;
- all returned class predictions and LDA scores are finite and deterministic;
- `R CMD check --as-cran` reports no errors or warnings.

No grouped-sensitivity result from the interrupted run should be used in the
manuscript, figures, tables, registry, or PathoFMPred release until this gate
passes.
