#!/usr/bin/env bash
set -euo pipefail

cd /Users/stefano/Documents/Titan/titan-prediction
exec env \
  TITAN_START_SCRIPT=R/10_literature_crosswalk.R \
  TITAN_WORKERS=6 \
  TITAN_BASELINE_WORKERS=6 \
  TITAN_BACKEND=cpu \
  TITAN_RUN_999=true \
  TITAN_RUN_9999=true \
  /Library/Frameworks/R.framework/Resources/bin/Rscript R/run_all.R \
  >> logs/resume_from_R16_20260919.log 2>&1
