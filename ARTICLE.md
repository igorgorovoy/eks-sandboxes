# ARTICLE.md (draft)

<!--
Status: DRAFT 1, for CB Speed Run 2 (submit window Nov 16-23).
Language: English (publication target - AWS Builder Center).
Honesty rules for this draft:
- Every number in [BRACKETS] must come from a real benchmark run before submit.
- Every claim marked (verify) must be confirmed on the cluster before submit.
- Do not submit with placeholders left in.
-->

# Hardware-isolated AI agents on EKS with Nitro Sandboxes: a hands-on guide, with a gVisor comparison

Your AI agent writes code and needs to run it. The code came out of a model that reads the internet, and you cannot trust it. So the execution environment needs a real isolation boundary. On November 9, 2026, AWS shipped a new one: [Nitro Sandboxes](https://aws.amazon.com/blogs/aws/TODO-announcement-link), lightweight VMs managed by the Nitro Hypervisor, now available for EKS pods, ECS tasks and standalone EC2 VMs at no extra charge.

This guide shows how to actually implement agents on them: bring up a cluster where Nitro Sandboxes, gVisor and plain runc run side by side on identical instances, wire the "agent runs code in an isolated pod" pattern end to end, and measure what the isolation costs in start time and density.

## Three isolation levels, on the same instance

Run one `m8i.xlarge` three ways and the difference is visible with `uname -r` on a pod:

| Runtime | Boundary | Kernel the pod runs |
|---|---|---|
| runc (the default) | namespaces, cgroups | the host kernel (AL2023) |
| [gVisor](https://gvisor.dev) via `runsc` | user-space syscall interception | a synthetic kernel, the Sentry |
| Nitro Sandbox | a hardware VM under the Nitro Hypervisor | its own guest kernel |

The middle option looks like a software trick because it is one: gVisor reimplements a Linux kernel in a user-space process. It works surprisingly well, and it runs on any instance type.

The Nitro Sandbox route is different. Each pod becomes a micro-VM the way a Lambda function is one: the pod container runs inside a VM with its own kernel, started on the same EC2 instance you already rent. Two things follow from this:

1. Secrets can be released only to sandboxes that prove their integrity with cryptographic attestation: the sandbox's measurements live in PCR registers, and a KMS key policy with `kms:RecipientAttestation:PCR` conditions releases decryption keys only on a match. One caveat straight from the docs: without that key policy (or another external verifier) the measurement is recorded but never checked. That matters for regulated workloads and for anything where an agent holds credentials.
2. The isolation boundary is hardware, the same one AWS uses between your instances and between a Lambda workload and its host.

The old approach for "a real VM inside a pod" was Kata Containers on nested virtualization. It still works, but it now has an asterisk: nested virtualization is limited to 8th-gen Intel instances (c8i/m8i/r8i), it is not available on Graviton, and there is no attestation. Nitro Sandboxes lift all three (Graviton support: verify against the announcement before submit).

## Bringing up the cluster

EKS Auto Mode with Kubernetes 1.36 or newer is the shortest path, and enabling Nitro Sandboxes for pods is a one-line change:

```yaml
spec:
  runtimeClassName: isolated-sandbox
```

Everything else in the pod stays native: Pod Identity, VPC CNI, EBS/EFS/S3 volumes, CloudWatch all work as usual.

The cluster in this guide ([full Terraform here](TODO-repo-link-or-private-repo-note)) is one Auto Mode cluster with a NodePool pinned to `m8i.xlarge`, plus gVisor on a managed node group using the same instance type:

```yaml
# Auto Mode NodePool for Nitro Sandbox pods
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: sandbox-nitro
spec:
  template:
    metadata:
      labels: { sandbox-runtime: nitro }
    spec:
      taints:
        - { key: sandbox, value: nitro, effect: NoSchedule }
      requirements:
        - key: eks.amazonaws.com/instance-family
          operator: In
          values: ["m8i"]
```

```yaml
# One of the four smoke-test pods
apiVersion: v1
kind: Pod
metadata:
  name: nitro-codeexec
  annotations:
    sandbox.amazonaws.com/network-isolated: "true"   # no network device at all
spec:
  runtimeClassName: isolated-sandbox
  nodeSelector: { sandbox-runtime: nitro }
  tolerations:
    - { key: sandbox, operator: Equal, value: nitro, effect: NoSchedule }
```

Two details worth knowing before you debug:

- Pods without the taint toleration and nodeSelector land on the standard runtime. The isolation is opt-in, per pod, not per cluster.
- The `network-isolated` annotation removes the pod's network device entirely: no DNS, no IMDS, no Pod Identity credentials. That has a side effect you will hit immediately: HTTP and TCP probes stop working, so such pods take exec probes only. `kubectl port-forward` does not reach a network-isolated pod at all; logs, exec and stats keep working over a vsock channel that does not depend on the pod network.

The full bring-up on a default VPC took about 20 minutes with `terraform apply` (31 resources: private subnets, a NAT gateway, the cluster, admin add-ons, two node groups). The interesting parts live in three files: the NodePool above, a `RuntimeClass` for gVisor, and a NodeConfig that teaches containerd about `runsc` and installs gVisor on node boot.

After the cluster came up, four probe pods confirmed the diagram from the table: runc printed the host kernel (`6.18.56`, shared with its node), the Nitro Sandbox pod printed a different guest kernel (`6.18.54`) and exactly the vCPU count it requested, the network-isolated pod saw only `lo` and a dead DNS (`wget: bad address`, then `NETWORK: blocked`), and the gVisor pod printed the Sentry kernel (`4.19.0-gvisor`). Full outputs live in the repo, `evidence/runtime-evidence.txt`.

## The pattern: agent with network, code without it

The setup everyone actually wants is two roles:

```mermaid
sequenceDiagram
    participant L as LLM API
    participant AG as agent pod (isolated-sandbox, network on)
    participant CM as ConfigMap
    participant CE as code-exec pod (network-isolated)
    AG->>L: prompt
    L-->>AG: generated code
    AG->>CM: puts code (ConfigMap, base64 binaryData)
    AG->>CE: creates the pod, mounts the ConfigMap
    CE->>CE: runs the code, output to stdout
    AG->>CE: fetches pod logs (kubelet exec channel, not pod network)
    CE-->>AG: result
    AG->>L: continues the loop
```

The agent pod keeps its network: it talks to the model API and to the Kubernetes API. The generated code runs in a separate pod with no network device, no Pod Identity and no service account token. The two never share a socket, only API objects.

Three implementation notes that cost me the most time to figure out:

**emptyDir does not work for this, in two different ways.** It is pod-scoped, so two pods cannot share one. And putting both containers into one pod does not help either, because the `network-isolated` annotation is pod-level: the agent would lose its network too. This is why the exchange goes through the API server.

**The code travels as base64 in `binaryData`.** Kubernetes mounts a `binaryData` entry as the decoded bytes, and in shell it means zero JSON escaping. The agent script has no kubectl and no jq inside the sandbox VM; raw REST calls via curl over the service-account token and CA that kubelet already mounts work fine. alpine plus `apk add curl` is the whole dependency list.

**The code-exec pod mounts no service account at all.** Set `automountServiceAccountToken: false` on it. Generated code should not be able to call the Kubernetes API, create pods, or read secrets, even though it already has no network. The RBAC around the agent is namespace-scoped: create and delete pods and ConfigMaps in its own namespace, get pod logs, nothing else.

The full agent loop is one ConfigMap script and one pod spec; the manifest is [here](TODO-repo-link). On the default demo, the generated code self-checks its own isolation and prints, after running to completion in the network-isolated pod:

```
kernel: 6.18.54
interfaces: dummy0 lo
wget: bad address 'aws.amazon.com'
NETWORK: blocked — isolation works
SA token: absent — expected
uid: 0
```

All three implementation hypotheses from this section held in practice: the ConfigMap mounts inside the sandbox VM, kubelet exec and log access work with no network device, and the service-account token is absent with `automountServiceAccountToken: false`.

## What isolation costs

Method: for cold start, N pods of each runtime, time from `kubectl apply` to Ready, measured per pod from `creationTimestamp` to the Ready condition, plus wall time; run twice, the first run includes node bootstrap. For density, keep applying 1-vCPU `sleep` pods until Ready stops growing.

| Metric | runc | Nitro Sandbox | gVisor |
|---|---|---|---|
| Cold start on a warm node, per pod | 1-5 s (9 runs) | 3-4 s best, 37 s p90 | n/a (censored, see below) |
| Density: 1-vCPU pods per m8i.xlarge | 3-4 | 15 Ready out of a 20-slot cap | 2 |
| Node cost per pod-hour | ~$0.07 | ~$0.02 | ~$0.12 |
| Cold start including node bootstrap | 215 s wall for 10 pods (4 new nodes) | same window + sandbox boot | n/a |

The gVisor cold-start number was censored in this session: both datapoints hit the same scheduling window, so treat that cell as future work rather than a result. Density was measured with a 250m vCPU *request* and a 1-vCPU *limit*: the scheduler packs by requests, so at a full 1-vCPU request the sandbox slot budget never gets to bind (observed live: 1 pod per busy node with three smoke pods already requesting the vCPUs).

Two expectations to check against your own run:

- Density. The docs are explicit here, and the numbers are higher than they look. Two caps apply per node, both sized at 5 times the node's vCPU count: the total vCPUs allocated across all sandboxes, and the number of sandboxes (the count cap is halved on CPU-overcommit instance types). A 4-vCPU `m8i.xlarge` therefore fits up to 20 single-vCPU sandboxes. Each sandbox pod also carries a fixed memory overhead the scheduler adds on top of the pod request: 256 MiB for `isolated-sandbox`, 512 MiB for `confidential-sandbox`. And on SMT instance types (all Intel, most AMD), core scheduling keeps two different sandboxes off the sibling threads of one core, so compute available to sandboxed pods is roughly half the advertised vCPUs; Graviton, one thread per core, is unaffected. That last detail changes the density math on `m8i` and is worth measuring directly. gVisor has none of these caps, so the crossover is where density beats start time.
- Cost. Auto Mode charges a management fee on top of EC2 that managed node groups do not have. For an honest per-pod-hour comparison, include it as a separate row. NAT for the private subnets is about $0.045 per hour, and it bills whether or not your cluster has traffic, so tear the demo down after the run.

## Cold start is two numbers, not one

The first benchmark run taught us more than the CLI output shows. A pod's time-to-Ready decomposes into two independent pieces, and they measure different risks.

**Sandbox startup on a node with free capacity.** A warm node with free sandbox slots brings a pod to Ready in 3-37 s (runc: 1-5 s). This is the honest cost of the isolation itself: image pull, VM boot, guest kernel init.

**Node provisioning.** A pod that does not fit lands in the scheduler's bin-packing decision; when it nominates a new nodeclaim, EC2 has to launch a node first, and that is 1-3 minutes of AMI boot plus kubelet join before any of your pods moves. In our runs, a first wave measured 215 s wall time where the second, warm run of the same spec measured 5 s. The difference is node bootstrap, not the sandbox.

And it can go much worse for a reason unrelated to sandboxes: our account hit **VcpuLimitExceeded** on the on-demand instance family (the default limit is 32 vCPUs per family for a fresh account). Seven m8i.xlarge nodes at 4 vCPUs each plus the system node filled the bucket, and every new nodeclaim retried with `InsufficientCapacityError` while pods sat in Pending for about half an hour until we freed capacity. Note for your own run: before density experiments, either raise the family vCPU limit or delete the nodeclaims you no longer need.

A practical consequence for benchmark methodology: measure the sandbox cost on warm nodes, and if you want to report "from nothing to running", measure that as a separate cold path that includes node bootstrap. Do not blend the two; they scale differently and break differently.

## Where it does not fit



- **No GPU passthrough yet.** Local inference inside a Nitro Sandbox is not possible today. If your agents need a local model, the sandbox runs it over the network or you stay on gVisor, which inherits host GPUs through runc-compatible devices.
- **No resize, no snapshot.** CPU and memory are allocated at pod boot: in-place resize is not supported, they stay unless you delete and recreate the pod with new requests. The primitive today also has no snapshot and restore and no live migration, so idle agents keep paying for their resources.
- **The agent's own privileges are the real risk.** Generated code is well fenced in this pattern (no network, no token, no API). The agent pod itself holds a create-pods permission in its namespace, and admission today does not gate its pod specs. For production, this needs a Pod Security Standards policy on the namespace and an admission gate on `runtimeClassName` and hostPath, or moving pod creation out of the model-facing pod entirely. The write-up of this pattern should state this plainly; the demo cannot.
- **Public cluster endpoint.** This guide's cluster keeps `endpoint_public_access` on without a CIDR allowlist for the sake of a short demo. In anything long-lived, restrict it (`endpoint_public_access_cidrs`) or drop it, private access is already on.
- **The vsock channel is a known surface.** The docs call it out themselves: the vsock device used for shim-to-agent communication is accessible to processes inside the guest, and any parent process with access to the Firecracker vsock socket can connect guest-bound ports, including on network-isolated pods. Not a classic network bypass, but the "no network device" line deserves this asterisk in a security review.

## Takeaways

For agents that execute model-written code on EKS today:

1. Nitro Sandboxes are the cheapest way to get a hardware isolation boundary per pod, and the only one with attestation. Enablement is one line, and the pod stays native.
2. gVisor still wins where density matters more than the boundary strength, and where GPUs matter.
3. Nested virtualization for Kata is the legacy path now. If you have it running, fine; for new work, Nitro Sandboxes replace it on the same instance class you likely already run.

The pattern above (agent with network, code without) is small enough to be owned by one person and strict enough to survive a security review, with the two admission gaps from the last section closed first.

All Terraform, manifests, the agent pod setup and the benchmark script are in [TODO: public repo link by submit time]; numbers in the tables get filled in from the benchmark runs recorded in `benchmark-results.csv`.

## Sources

- [Sandboxing on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing.html) — key features, attestation, encrypted images
- [Nitro Sandboxes considerations, EKS](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing-limitations.html) — density caps, SMT core scheduling, resize and device limitations
- [Network isolation](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing-network-isolation.html) — exec probes, vsock channel behavior
- [Autoscaling with Nitro Sandboxes](https://docs.aws.amazon.com/eks/latest/userguide/autoscaling.html) — slot overhead (256/512 MiB), provisioning
- [Setup paths on EKS](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing-isolated-setup.html) — Auto Mode vs node groups, K8s >= 1.36
- [Amazon EC2 Nitro Sandboxes](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/amazon-ec2-nitro-sandboxes.html) — instance support (Intel/AMD/Graviton), when to use what
- [gVisor documentation](https://gvisor.dev/docs/)

<!--
PRE-SUBMIT TODO (from PLAN.md, experiment day):
[ ] run smoke tests, fill in kernel evidence
[ ] verify custom NodePool scheduling hypothesis (or drop that paragraph)
[ ] run coldstart twice per runtime, fill p50/p90
[ ] run density, fill the table and compare against the documented caps (5x vCPU allocation + 5x sandbox count, halved on CPU-overcommit types; 256 MiB overhead per pod; SMT core-scheduling effect on m8i)
[ ] run E2E agent demo, fill results
- verified against official docs Nov 10 2026: Graviton support, attestation KMS PCR caveat, no-GPU passthrough, no resize/snapshot/live-migration, K8s >= 1.36, no extra charge, exec/logs over vsock
[ ] pin gVisor release in gvisor.mime and cite versions
[ ] confirm Auto Mode fee figure from billing/pricing docs
[ ] close or clearly flag the two security gaps before publishing manifests publicly
-->
