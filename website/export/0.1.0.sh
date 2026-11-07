#!/usr/bin/env bash
set -euo pipefail

# A website instance ($1) keeps all its data in store/website/<id>/data, which
# every snapshot reads in place. Nothing to dump, no volumes. See lib/export.sh
# for the contract.

ID="${1:?website export needs an instance id}"
[[ -d "../store/website/$ID/data" ]] || { echo "store/website/$ID/data is missing." >&2; exit 1; }
echo "Website instance $ID keeps its data in store/website/$ID/data."
