# Author actions required before submission

The authors confirmed that no competing interests and no grant funding apply.
The manuscript now includes a complete CRediT contribution statement.

The remaining archival actions are:

1. Create a versioned source release from the synchronized commits and archive
   it with Zenodo or an equivalent repository.
2. Insert the resulting source-release tag, immutable commits and DOI in the
   manuscript and data-availability statement.

The current working tree is not an archival release and must not be cited as one.

## Completed repository and model-release actions

The synchronized pull requests were merged on 20 September 2026:

1. `tkcaccia/titan-prediction` pull request 1, merge commit
   `48f3ae935c729d899880e7e6d72372ef87c7a2b0`.
2. `tkcaccia/PathoFMPred` pull request 1, merge commit
   `1813a92e8993cf391e976c3870d15076592db0e2`.
3. `tkcaccia/PathoFMPred-private` pull request 1, merge commit
   `e050dcf6726f1b1ad5ddbab5a6d190f5b70b2653`.

The public package is licensed under MIT for contributor-authored source code
and documentation. Fitted objects are excluded from that grant. The public
`models-v2` release contains only the audited Giga-SSL and Prov-GigaPath
collections. GitHub records the same SHA-256 digests pinned by the package,
and an end-to-end `fetch_pathofmpred_models()` test downloaded and validated
both objects. No TITAN fitted object was uploaded. The TITAN collection remains
private unless written redistribution permission is obtained from the upstream
rights holder.

The existing `models-v1` release contains an older fitted-object snapshot and
does not match the checksums pinned by the current package. It must not be
presented as the model release for version 0.3.0.

## Deferred archival action

At the corresponding author's request, no DOI is being created at this stage.
A versioned source-code release and persistent DOI should be created from the
final synchronized commits before final submission or acceptance. The
`models-v2` asset release is not a substitute for that source-code archive.
