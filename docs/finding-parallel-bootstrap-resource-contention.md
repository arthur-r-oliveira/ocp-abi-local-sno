# Finding: Parallel SNO Bootstrap Fails Under Hypervisor Resource Contention

**Date**: 2026-09-28
**CI Run**: [#36280487260](https://github.com/arthur-r-oliveira/ocp-abi-local-sno/actions/runs/36280487260)
**Severity**: Intermittent — sno-a install fails (exit 6) while sno-b succeeds on the same run

## Summary

When both SNO nodes (sno-a and sno-b) bootstrap simultaneously on the same KVM hypervisor, sno-a's kube-apiserver static pod installer times out with `context deadline exceeded`, causing cascading operator failures and install timeout (exit 6). sno-b completes successfully on the same run. The Day-2 PRP configuration is skipped because sno-a never reaches install-complete.

## Environment

| Resource | Value |
|----------|-------|
| Hypervisor | hypervisor.lab.local |
| CPU | 2x Intel Xeon E5-2699 v3 @ 2.30GHz (36 cores / 72 threads) |
| Host RAM | 46 GiB + 24 GiB swap |
| VM allocation (each) | 8 vCPU + 16 GiB RAM |
| VMs combined | 16 vCPU + 32 GiB RAM (70% of host memory) |
| Storage | Both VM disks (~45 GB each) on single XFS/LVM volume (`/home`) |
| OCP version | 5.0.0-rc.2 |

## Evidence

### sno-a failure chain

1. **kube-apiserver installer pod timeout** — the static pod installer couldn't reach the kube-apiserver within its 2-minute deadline:
   ```
   NodeInstallerDegraded: F0927 01:32:12.669344  1 cmd.go:113]
     Get "https://172.30.0.1:443/api/v1/namespaces/openshift-kube-apiserver/pods
     ?labelSelector=app%3Dinstaller": context deadline exceeded
   ```

2. **kube-apiserver never rolled out** — stuck at revision 0:
   ```
   StaticPodsAvailable: 0 nodes are active; 1 node is at revision 0;
   0 nodes have achieved new revision 4
   ```

3. **Cascading 401 errors** across all OpenShift API services (apps, authorization, build, image, project, route, security, template) — all returning HTTP 401 because the apiserver was never ready.

4. **5 operators never initialized**: authentication, image-registry, olm, openshift-apiserver, openshift-samples.

5. **7 timeout/deadline-exceeded errors** in sno-a's install log (20 KB) vs sno-b's clean install (5 KB).

### Resource contention indicators

- **Memory**: 32 GiB allocated to VMs out of 46 GiB total (70%). During bootstrap, host page cache for two 45 GB qcow2 images competing on remaining 14 GiB.
- **Storage I/O**: Both VMs write to disk images on the same XFS/LVM volume. Bootstrap involves heavy I/O: unpacking container images, writing etcd, static pod creation.
- **sno-b won the race**: completed install successfully. sno-a's installer pod starved on I/O or CPU, couldn't meet the 2-minute kube-apiserver readiness deadline.

### What we lack (no historical metrics)

`sysstat` (sar) is **not installed** on the hypervisor. We have no CPU utilization, I/O wait, or memory pressure data from the CI run timeframe. The evidence above is circumstantial — consistent with resource contention but not definitively proven.

## Recommendations

### Immediate (install sysstat for evidence)

```bash
dnf install -y sysstat
systemctl enable --now sysstat
```

This gives `sar` data (CPU, I/O, memory, swap) in 10-minute intervals at `/var/log/sa/`. On the next failure, run:
```bash
# CPU and I/O wait during the CI window
sar -u -f /var/log/sa/sa27 -s 23:45:00 -e 01:45:00

# Disk I/O
sar -d -f /var/log/sa/sa27 -s 23:45:00 -e 01:45:00

# Memory pressure
sar -r -f /var/log/sa/sa27 -s 23:45:00 -e 01:45:00
```

### Mitigation options

1. **Stagger bootstrap** — start sno-b 10-15 minutes after sno-a so the heaviest I/O phases don't overlap. Simplest change, keeps the same total time.

2. **Separate storage** — put each VM's qcow2 on a different physical disk or LVM volume to eliminate I/O contention.

3. **Increase install-complete timeout** — currently 5400s (90 min). If sno-a just needs more time due to contention, a longer timeout may be enough. Risk: masks real failures.

4. **Sequential install in CI** — run Test Case 2 as sno-a-first, then sno-b, instead of parallel `wait-for install-complete`. Doubles wall-clock time (~2h instead of ~1h) but eliminates contention.

## Reproducing

The failure is intermittent. It occurred on CI run #36280487260 (Sep 26-27, 2026) but not on the previous run (Sep 25). Running the Day-2 script manually after sno-a recovered confirmed the script itself is correct — the issue is purely at install time.
