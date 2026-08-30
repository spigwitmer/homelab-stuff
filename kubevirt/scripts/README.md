# kubevirt/scripts

One-shot runtime helpers for breaking kubevirt deadlocks that the IaC in this
repo can't fix on its own. These are **not** IaC and are not auto-run by
ArgoCD. Run them by hand when you see a specific symptom.

## break-deadlock.sh

**When to run it:**

ArgoCD's `homelab-deploy-kubevirt-cr` Application fails to sync with:

```
failed calling webhook "kubevirt-update-validator.kubevirt.io":
context deadline exceeded
```

…and `kubectl get endpoints kubevirt-operator-webhook -n kubevirt` shows
`<none>` for ENDPOINTS.

**What it does:**

1. Patches the `virt-api` and `virt-controller` Deployments' `nodeAffinity`
   directly to require workers (charmander / cubone) and explicitly exclude
   `control-plane` / `master` (k8s-master-1).
2. Deletes any kubevirt pods that are not in `Running` state, so they get
   rescheduled onto workers per the new affinity.

**Why it's needed (the deadlock):**

When `virt-api` pods are stuck on k8s-master-1 (originally due to a Cilium
endpoint-creation rate-limit; the Pi is the only node that meets the
upstream control-plane/master affinity), the operator's validating webhook
has no backing endpoints. ArgoCD then can't apply the KubeVirt CR with
`customizeComponents` because the webhook times out. The CR stays empty, the
`virt-api` / `virt-controller` Deployments keep their upstream
control-plane/master affinity, and the pods stay stuck on the Pi — no
progress is possible through the IaC alone.

**Idempotency:**

Safe to re-run. Once `virt-api` is healthy on a worker, the operator's
webhook comes back, ArgoCD syncs the KubeVirt CR, and
`spec.customizeComponents.patches` re-asserts the same affinity (no-op).
The operator owns the Deployments going forward; this script's patches get
folded into the same final state.

**Sequence after running:**

1. Wait for `virt-api` / `virt-controller` / `virt-operator` to land on
   charmander or cubone (`kubectl get pods -n kubevirt -o wide`).
2. Re-sync `homelab-deploy-kubevirt-cr` in the ArgoCD UI (or
   `argocd app sync homelab-deploy-kubevirt-cr`).
3. The CR's `customizeComponents.patches` lands; operator processes it;
   virt-api / virt-controller Deployments' affinity matches what's already
   in the cluster; ArgoCD shows Synced + Healthy.

**Does NOT fix:**

- Cilium agent in `ImagePullBackOff` on cubone (separate, bootstrap Ansible)
- Cilium endpoint rate-limit on k8s-master-1 (separate, bootstrap Ansible)

If Cilium on cubone is still broken, the new pods may reschedule there and
still fail to start. Resolve Cilium first.