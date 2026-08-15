# Data and software provenance

Raw files are not committed. The pipeline records SHA-256 checksums locally
in `results/tables/source_manifest.csv`.

| Family | Source | Role |
|---|---|---|
| Histology features | Ding et al., *Nature Medicine* (2025), TITAN | Frozen 768-dimensional slide embeddings |
| Immune/inflammatory | Thorsson et al., *Immunity* (2018) | Continuous patient-level targets |
| Driver mutations | Bailey et al., *Cell* (2018); TCGA MC3 | Cancer-specific binary targets |
| Oncogenic pathways | Sanchez-Vega et al., *Cell* (2018), Table S4 | Ten binary pathway-alteration targets |
| Aneuploidy | Taylor et al., *Cancer Cell* (2018), Table S2 | Aneuploidy score, arm burdens, genome doubling |
| Gene fusions | Gao et al., *Cell Reports* (2018), Table S1 | Fusion burden and recurrent fusion targets |
| MSI | Bonneville et al., *JCO Precision Oncology* (2017); cBioPortal Datahub | MANTIS and MSIsensor scores/status |
| PLS software | fastPLS 0.99.20 or later | Nested PLS/PLS-LDA modelling |

The curated prior-histology mutation claims used for the discussion crosswalk
are stored in `data/reference/prior_mutation_claims.csv`. Each row records the
study, cancer, gene, reported metric/evidence and a direct article URL; current
TITAN results are joined by `R/10_literature_crosswalk.R` rather than entered
manually into the manuscript.

Primary publication links:

- TITAN: https://doi.org/10.1038/s41591-025-03982-3
- PanCancer immune landscape: https://doi.org/10.1016/j.immuni.2018.03.023
- MC3 mutation calls: https://doi.org/10.1016/j.cels.2018.03.002
- Cancer driver catalogue: https://doi.org/10.1016/j.cell.2018.02.060
- Oncogenic pathways: https://doi.org/10.1016/j.cell.2018.03.035
- Aneuploidy: https://doi.org/10.1016/j.ccell.2018.03.007
- Driver fusions: https://doi.org/10.1016/j.celrep.2018.03.050
- MSI landscape: https://doi.org/10.1200/PO.17.00073
- cBioPortal Datahub: https://github.com/cBioPortal/datahub

The supplied Bonneville spreadsheets `ds_po.17.00073-4/5.xlsx` contain only
the ACC/CESC/MESO secondary analysis (480 and 480 rows), not the complete
11,139-pair pan-cancer MSI landscape. The primary MSI ingest therefore uses
the authors' MANTIS fields distributed across the 32 TCGA PanCancer Atlas
studies in the cBioPortal Datahub. The supplied sheets are retained as an
independent value-level audit for overlapping participants.
