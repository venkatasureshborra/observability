#!/usr/bin/env bash
# Teardown script - removes the KinD cluster entirely
set -euo pipefail

echo "Deleting KinD cluster 'observability'..."
kind delete cluster --name observability
echo "Done. All resources have been removed."
