#!/bin/sh

helm -n cert-manager upgrade --install --create-namespace \
    webhook-linode -f values-override.yaml .
