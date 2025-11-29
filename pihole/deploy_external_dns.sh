#!/bin/sh

set -xeuo pipefail

kubectl -n pihole-system create secret generic pihole-password --from-file=EXTERNAL_DNS_PIHOLE_PASSWORD=app-pass.txt
kubectl -n pihole-system apply -f external-dns-pihole.yaml
