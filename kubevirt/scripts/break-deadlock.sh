#!/usr/bin/env bash
# break-deadlock.sh — one-shot runtime fix for the kubevirt scheduling deadlock.
#
# The kubevirt-update-validator.kubevirt.io webhook can't be reached when the
# cluster is in its current state: virt-api pods are stuck on k8s-master-1 due
# to Cilium endpoint rate-limiting (HTTP 429). No virt-api → no webhook
# endpoint → ArgoCD can't apply the KubeVirt CR → customizeComponents stays
# empty → virt-api/virt-controller Deployment affinity stays pinned to
# control-plane/master → pods stay stuck on k8s-master-1. Death spiral.
#
# This script breaks the loop by:
#   1. Patching virt-api and virt-controller Deployments' nodeAffinity directly
#      to the worker-only rule. KubeVirt's validating webhook only validates
#      KubeVirt CRs, not Deployments, so kubectl patch bypasses it.
#   2. Deleting the stuck pods in the kubevirt namespace so they reschedule
#      onto workers per the new affinity.
#
# Idempotency: safe to rerun. Once virt-api is healthy and ArgoCD reconciles
# the KubeVirt CR, the operator's customizeComponents patches re-assert the
# same affinity (idempotent), and the operator owns the Deployment going
# forward. The script can stay in the repo for future deadlocks but should
# never be auto-run.
set -euo pipefail

NS=kubevirt

echo "==> Patching virt-api / virt-controller Deployment nodeAffinity (workers only)"
kubectl patch deployment virt-api -n "$NS" --type=strategic --patch '
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/worker
                operator: Exists
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
              - key: node-role.kubernetes.io/master
                operator: DoesNotExist
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: kubevirt.io
                  operator: In
                  values: ["virt-api"]
              topologyKey: kubernetes.io/hostname
            weight: 1
'
kubectl patch deployment virt-controller -n "$NS" --type=strategic --patch '
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/worker
                operator: Exists
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
              - key: node-role.kubernetes.io/master
                operator: DoesNotExist
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: kubevirt.io
                  operator: In
                  values: ["virt-controller"]
              topologyKey: kubernetes.io/hostname
            weight: 1
'

echo "==> Deleting non-Running kubevirt pods (forces reschedule on workers)"
kubectl delete pod -n "$NS" --field-selector 'status.phase!=Running' --force --grace-period=0

echo "==> Done. Watch: kubectl get pods -n $NS -o wide"