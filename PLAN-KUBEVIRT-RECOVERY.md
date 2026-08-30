# kubevirt Webhook Deadlock — Recovery Notes

## Status: partial (caller should restart kube-apiserver in bootstrap Ansible)

The IaC is fully in place and pushed to `origin/master`:

- `kubevirt/upstream/kubevirt-operator.yaml` — kubevirt **v1.9.0** (bumped from v1.7.0 → v1.7.4 → v1.9.0 to chase the upstream fix for `pkg/virt-operator/webhooks/kubevirt-update-admitter.go`'s `getAdmissionReviewKubeVirt` nil-pointer panic)
- `kubevirt/kubevirt-cr.yaml` — KubeVirt CR with `customizeComponents.patches[type: strategic]` for virt-api + virt-controller, worker-only affinity (`worker=Exists + control-plane/master=DoesNotExist`)
- `kubevirt/opencode-vm.yaml` — schema-correct for v1.7.0+ (`spec.pvc`, `secretRef`, `worker-only affinity`)
- `homelab-deploy/templates/application-kubevirt.yaml` + `application-kubevirt-cr.yaml` + updated `application-opencode.yaml`
- `kubevirt/scripts/break-deadlock.sh` + `README.md` (still useful for the operator's VWC-revert cycle)

## What's working

- ✓ Cilium agents + operator healthy on all 3 nodes
- ✓ virt-operator pods on charmander + cubone
- ✓ virt-handler DaemonSet on workers
- ✓ virt-api + virt-controller **on workers** (one of each Running)
- ✓ KubeVirt CR has `customizeComponents.patches` applied (the Deployment's `nodeAffinity` is now: `worker=Exists + control-plane/master=DoesNotExist` from `customizeComponents`, plus the operator's default `control-plane/master=Exists` terms OR'd in the same `nodeSelectorTerms` list)

## What's not working

The kubevirt webhook still times out. v1.9.0 has the same nil-pointer panic as v1.7.x in `getAdmissionReviewKubeVirt`. Symptoms:

```
Error from server (InternalError): Internal error occurred: failed calling webhook
  "kubevirt-update-validator.kubevirt.io" (or "virtualmachines-mutator.kubevirt.io"):
  failed to call webhook: Post "https://...svc:443/...-validate-update?timeout=10s":
  context deadline exceeded
```

Direct `curl` to virt-api succeeds (`HTTP 200 OK` with `allowed: true`), so the webhook handler *can* answer, but the kube-apiserver's webhook client times out at 10s — either the validator is too slow on the path the kube-apiserver takes, or the cache has the old MWC.

## The two-part deadlock

1. `failurePolicy: Ignore` patches on the VWC/MWC get reverted by the operator's reconcile loop (operator is the source of truth for these).
2. The kube-apiserver's webhook cache doesn't see the patched `timeoutSeconds: 30` from the MWC; the URL still has `?timeout=10s`. The cache refresh interval is on the order of 30-60s.

## What I tried (in order)

1. **Patched MWC/VWC `failurePolicy: Ignore` + `timeoutSeconds: 30`** — operator reverts within seconds.
2. **Patched + immediate `kubectl apply`** (race window) — the kube-apiserver's webhook cache had the old config.
3. **Restarted the kube-apiserver pod** — the static pod is reconciled by the kubelet, the container restarts in place (`startedAt` did change), but the webhook client code still uses the URL with the 10s timeout.
4. **Patched MWC + waited 60s + applied** — cache did not refresh, URL still `?timeout=10s`.
5. **Deleted the entire `virt-operator-validator` VWC** — operator recreates it within seconds, and during the window the kube-apiserver's cache still has the entry.
6. **Direct `curl` to the webhook** — returns `HTTP 200 OK` with `allowed: true`. The handler works when not under the kube-apiserver's webhook client.

## What the operator logs show

The panic stack from v1.7.4 and v1.9.0 is identical:

```
panic: runtime error: invalid memory address or nil pointer dereference
kubevirt.io/kubevirt/pkg/virt-operator/webhooks.getAdmissionReviewKubeVirt(...)
    pkg/virt-operator/webhooks/kubevirt-update-admitter.go:144 +0x26
kubevirt.io/kubevirt/pkg/virt-operator/webhooks.(*KubeVirtUpdateAdmitter).Admit(...)
    pkg/virt-operator/webhooks/kubevirt-update-admitter.go:68 +0x45
kubevirt.io/kubevirt/pkg/util/webhooks/validating-webhooks.Serve(...)
    pkg/util/webhooks/validating-webhooks/validating-webhook.go:68 +0xee
```

`getAdmissionReviewKubeVirt` body in v1.7.4 and v1.9.0 is byte-identical. The `v1.9.0` is supposed to add more validators (validateVirtTemplateDeployment, validateRoleAggregationStrategy, validateMigrationConfiguration, validateFeatureGates) that may or may not be the cause of the slowness — but the panic in `getAdmissionReviewKubeVirt` predates those.

## What to try next (in priority order)

1. **Restart the kube-apiserver pod cleanly** (the user must do this — I bounced it twice but the container kept the same process / in-memory state of the webhook client). The right way is to ssh to k8s-master-1 and either:
   - `crictl stop $(crictl ps -a -q --name kube-apiserver*)` (force a new container ID)
   - or just `systemctl restart kubelet` (will reconcile the static pod)
2. **If that still doesn't clear the cache**, the next thing is to edit the kubevirt-operator Deployment env to reduce validator timeouts, or just accept the broken webhook and apply the VM manifest **by writing directly to etcd** (last resort; requires the etcd client cert).
3. **Long-term**: file the upstream panic as a kubevirt issue with the stack trace, and bump to whatever version fixes it.

## Workarounds that DO work for the cluster

- `kubectl apply -f kubevirt/opencode-vm.yaml` is blocked.
- But `kubectl exec` into virt-api + manual REST calls work — the webhook handler does work, the kube-apiserver's webhook client is the bottleneck.
- Any patch that goes through the `kubevirt-update-validator` webhook is blocked (i.e., the CR).
- Patches that don't go through kubevirt admission (e.g., Deployment, ConfigMap, Service) work fine — `homelab-deploy-kubevirt` is Synced, the operator's VWC/MWC are in place, the install strategy configmap was hand-crafted with v1.9.0's deployment ID `7094f6e16396cf2ff9af28bc76abc121430fa6c0`.

## File summary

```
kubevirt/
├── upstream/kubevirt-operator.yaml   # v1.9.0 manifest (was v1.7.0) + worker-affinity + trimmed tolerations
├── kubevirt-cr.yaml                   # KubeVirt CR with type: strategic patches
├── opencode-vm.yaml                   # VirtualMachine (spec.pvc, secretRef, worker-only affinity)
├── opencode-userdata.yaml             # Secret (cloud-init)
├── opencode-svc.yaml                  # Service (LoadBalancer)
├── scripts/
│   ├── break-deadlock.sh              # one-shot runtime fix for the operator's VWC-revert loop
│   └── README.md
```

## Recommended follow-up work-items

- [ ] **Bootstrap Ansible: pin cilium image to a stable tag** (`quay.io/cilium/cilium:vX.Y.Z` instead of `cilium-ci:latest`). cubone's clock was 6 months behind — fixed, but the `:latest` tags caused the original cert issue.
- [ ] **Bootstrap Ansible: bump kubevirt to whatever version fixes the webhook panic** (v1.10+, or a patch version that backports the `getAdmissionReviewKubeVirt` nil check). Update `kubevirt/upstream/kubevirt-operator.yaml` and `application-kubevirt.yaml` `targetRevision`.
- [ ] **Restart kube-apiserver** on k8s-master-1 to clear its webhook cache (the user must do this — see "What to try next" above).
- [ ] **Clean up the orphan `service/bastion-ssh`** in `kubevirt` namespace (MetalLB IP 192.168.4.26 is allocated but no VM is using it). Out of scope of the opencode task but worth doing while we're here.
