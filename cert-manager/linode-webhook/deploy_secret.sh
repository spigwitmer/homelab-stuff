#!/bin/sh

set -euo pipefail

echo -ne 'token: '
read -s TOKEN

(kubectl -n cert-manager delete secret linode-credentials || exit 0)
kubectl -n cert-manager create secret generic linode-credentials \
    --from-literal=token=${TOKEN}
