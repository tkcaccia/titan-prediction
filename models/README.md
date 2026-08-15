# Fitted research models

`R/06_robustness_and_models.R` writes one `.rds` artifact for every supported
Tier-A or Tier-B cancer–endpoint model and creates `model_registry.csv` with
its SHA-256 digest. Each artifact contains:

- the fitted `fastPLS` object;
- the endpoint family, cancer type and outcome type;
- the exact ordered 768-feature input schema;
- the patient mean-pooling rule used for multi-slide cases;
- selected component count and training sample counts;
- software version and a research-only intended-use statement.

Use `examples/predict_titan_features.R` to validate, pool and predict new TITAN
slide features. The example accepts multiple slides per patient and returns one
patient-level prediction.

Model `.rds` files are excluded from Git pending written clarification from the
TITAN rights holder because TITAN's upstream terms restrict redistribution of
models trained on TITAN outputs. The public repository contains the complete
fitting code and registry; local model generation remains reproducible from the
documented inputs.
