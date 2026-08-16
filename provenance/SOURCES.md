# Data and software provenance

Raw files are not committed. The pipeline records SHA-256 checksums locally
in `results/tables/source_manifest.csv`. Installed package versions, available
remote commit metadata and the explicitly pinned fastPLS/TCGAmutations source
references are written to `results/tables/software_manifest.csv`.

| Family | Source | Role |
|---|---|---|
| Histology features | Ding et al., *Nature Medicine* (2025), TITAN | Fixed pretrained 768-dimensional slide representations |
| Immune/inflammatory | Thorsson et al., *Immunity* (2018) | Continuous patient-level targets |
| Driver mutations | Bailey et al., *Cell* (2018); TCGA MC3 | Cancer-specific binary targets |
| Oncogenic pathways | Sanchez-Vega et al., *Cell* (2018), Table S4 | Ten binary pathway-alteration targets |
| Aneuploidy | Taylor et al., *Cancer Cell* (2018), Table S2 | Aneuploidy score, arm burdens, genome doubling |
| Gene fusions | Gao et al., *Cell Reports* (2018), Table S1 | Fusion burden and recurrent fusion targets |
| MSI | Bonneville et al., *JCO Precision Oncology* (2017); cBioPortal Datahub | MANTIS and MSIsensor scores/status |
| Participant characteristics | Liu et al., *Cell* (2018), TCGA Clinical Data Resource | Descriptive age, recorded gender, race and broad stage summaries |
| PLS software | fastPLS 0.99.20, Git commit `dcf45cc` | Nested PLS/PLS-LDA modelling |

The curated prior-histology mutation claims used for the discussion crosswalk
are stored in `data/reference/prior_mutation_claims.csv`. Each row records the
study, cancer, gene, reported metric/evidence and a direct article URL; current
TITAN results are joined by `R/10_literature_crosswalk.R` rather than entered
manually into the manuscript.

The TITAN paper states that the Mass-340K pretraining corpus did not include
TCGA or PANDA. TCGA was instead used for downstream evaluation of the
pretrained model, including TCGA slide/report resources. The current study is
therefore not affected by reported TCGA pretraining overlap, but it is a
secondary analysis of a cohort used in TITAN's downstream evaluation and is
not an independent external validation. The exact local slide-report source is
`Data/TITAN/TCGA-Slide-Reports.csv`; matching coverage and unmatched selected
slides are written to `slide_report_coverage_audit.csv`.

Molecular absence is never treated as a negative label. MC3 wild type requires
a matched primary-tumour profile with no qualifying PASS protein-altering
variant in the gene. Fusion-negative status is assigned only within the Gao
study sample list. Source-specific coverage, missingness, primary-aliquot
multiplicity and patient aggregation are recorded in
`molecular_source_coverage_audit.csv` and `mutation_coverage_audit.csv`.
TCGA Clinical Data Resource matching and aggregate participant characteristics
are recorded in `tcga_cdr_match_audit.csv` and
`participant_characteristics_by_cancer.csv`; no patient-level clinical table is
redistributed.

Primary publication links:

- TITAN: https://doi.org/10.1038/s41591-025-03982-3
- PanCancer immune landscape: https://doi.org/10.1016/j.immuni.2018.03.023
- MC3 mutation calls: https://doi.org/10.1016/j.cels.2018.03.002
- Cancer driver catalogue: https://doi.org/10.1016/j.cell.2018.02.060
- Oncogenic pathways: https://doi.org/10.1016/j.cell.2018.03.035
- Aneuploidy: https://doi.org/10.1016/j.ccell.2018.03.007
- Driver fusions: https://doi.org/10.1016/j.celrep.2018.03.050
- MSI landscape: https://doi.org/10.1200/PO.17.00073
- TCGA Clinical Data Resource: https://doi.org/10.1016/j.cell.2018.02.052
- cBioPortal Datahub: https://github.com/cBioPortal/datahub
- TITAN model terms: https://huggingface.co/MahmoodLab/TITAN

The TITAN model card uses CC-BY-NC-ND 4.0 terms, restricts use to
non-commercial academic research, defines models trained on TITAN outputs as
derivatives, and prohibits redistribution of a model copy without permission.
Accordingly, this repository releases fitting and inference code, registry
metadata and hashes, but not the local fitted `.rds` objects unless written
permission or compatible terms are obtained.

The supplied Bonneville spreadsheets `ds_po.17.00073-4/5.xlsx` contain only
the ACC/CESC/MESO secondary analysis (480 and 480 rows), not the complete
11,139-pair pan-cancer MSI landscape. The primary MSI ingest therefore uses
the authors' MANTIS fields distributed across the 32 TCGA PanCancer Atlas
studies in the cBioPortal Datahub. The supplied sheets are retained as an
independent value-level audit for overlapping participants.
