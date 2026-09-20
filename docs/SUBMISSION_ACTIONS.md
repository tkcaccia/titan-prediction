# Author actions required before submission

The generated manuscript deliberately does not invent the following information.

1. Confirm the competing-interests declaration.
2. Supply the complete funding statement, including grant numbers.
3. Approve a CRediT contribution statement for every author.
4. Commit the synchronized analysis, tables, figures, manuscript and package-source snapshot.
5. Create a versioned GitHub release from that exact commit and archive it with Zenodo or an equivalent repository.
6. Insert the resulting release tag, immutable commit and DOI in the manuscript and data-availability statement.

The current working tree is not an archival release and must not be cited as one.

## Current release gates

The synchronized changes are staged in three green, mergeable pull requests:

1. `tkcaccia/titan-prediction` pull request 1.
2. `tkcaccia/PathoFMPred` pull request 1.
3. `tkcaccia/PathoFMPred-private` pull request 1.

They must be merged only after author approval. The public package is licensed
under MIT for contributor-authored source code and documentation. The fitted
objects are excluded from that grant. A `models-v2` release must be created
from the audited Giga-SSL and Prov-GigaPath collections before the public
download function can work. The TITAN collection must remain private unless
written redistribution permission is obtained from the upstream rights holder.

The existing `models-v1` release contains an older fitted-object snapshot and
does not match the checksums pinned by the current package. It must not be
presented as the model release for version 0.3.0.
