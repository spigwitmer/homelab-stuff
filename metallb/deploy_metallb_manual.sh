#!/bin/sh

helm -n metallb-system upgrade --install --create-namespace metallb -f helm/values-override.yaml metallb/charts/metallb
kubectl -n metallb-system apply -f static/
