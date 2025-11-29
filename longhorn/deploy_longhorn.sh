#!/bin/sh

helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --create-namespace \
    --version 1.10.1 \
    -f values-override.yaml
kubectl apply -f additional-storageclasses.yaml
