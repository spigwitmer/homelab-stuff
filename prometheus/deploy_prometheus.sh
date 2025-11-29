#!/bin/sh

helm -n prometheus upgrade --create-namespace --install \
    -f values-override.yaml \
    prometheus \
    oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack
