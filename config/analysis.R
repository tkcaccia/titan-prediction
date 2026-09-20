analysis_config <- list(
  seed = 20260815L,
  feature_pattern = "^titan_[0-9]{3}$",
  expected_features = 768L,
  components = 1:20,
  outer_folds = 5L,
  inner_folds = 5L,
  robustness_repeats = 5L,
  continuous_min_n = 50L,
  binary_min_positive = 20L,
  binary_min_negative = 20L,
  continuous_effect_gate = 0.20,
  binary_adjusted_ba_gate = 0.20,
  initial_permutations = 99L,
  extended_permutations = 999L,
  fdr_alpha = 0.05,
  svd_method = "rsvd",
  # Current fastPLS 0.3 defaults for the ordinary-shape rSVD profile.
  rsvd_oversample = 32L,
  rsvd_power = 5L
)
