# fastPLS 0.3 nested cross-validation fix validation

## Validated environment

- fastPLS version: 0.3
- Git commit: `8b9d03eb3274801e4c59209ff19d640b198c9ade`
- Backend: CPU
- Compiled BLAS: Apple Accelerate
- Method: SIMPLS with native randomized SVD
- rSVD controls: 10 oversampling vectors and two power iterations

## Original failure

The earlier fastPLS 0.3 build at commit
`8ab834154a985bfa94971bcfde0987350e30d08e` stopped inside
`fastPLS::pls.double.cv()` when an inner training fold had no estimable
response direction. The first affected project task was ACC with the endpoint
`T Cells CD4 Memory Activated`, 54 observations, 768 predictors, and a response
containing 52 zeros. The compiled path raised
`cross-validation score projection dimensions are invalid`.

## Fix and acceptance gate

Commit `8b9d03eb3274801e4c59209ff19d640b198c9ade` was installed from GitHub into
the project library. The standalone regression gate at
`tools/reproduce_fastpls_0.3_cv_error.R` verifies all of the following:

- nested cross-validation completes for one component and for components 1 to
  10 under centering, autoscaling, and no scaling;
- all predictions are finite;
- every requested component remains present in every inner tuning path;
- repeated calls with the same seed return identical predictions;
- a completely constant response returns the fold-training response mean;
- the formerly failing ACC project endpoint completes with finite predictions
  and a complete 1-to-10-component tuning path.

The package-level PLS-LDA contract test in
`tests/testthat/test-fastpls-lda.R` also passes. The gate can be reproduced
from the repository root with:

```sh
Rscript tools/reproduce_fastpls_0.3_cv_error.R
Rscript -e '.libPaths(c(normalizePath(".Rlib"), .libPaths())); testthat::test_file("tests/testthat/test-fastpls-lda.R")'
```

The full atlas rerun is permitted only after these checks pass. Results from
fastPLS 0.99.20 are not accepted into the new release outputs.

The same commit also resolves the grouped PLS-LDA component-path failure
documented in `provenance/fastPLS_0.3_LDA_component_path_request.md`. Both
single and nested cross-validation now retain requested components 1 to 10,
record effective fold-specific counts, and return finite deterministic scores
for the synthetic grouped test and the exact ACC-WNT project analysis.
