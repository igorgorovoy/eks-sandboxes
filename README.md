# eks-sandboxes

A working demo for the article *Hardware-isolated AI agents on EKS with Nitro Sandboxes: a hands-on guide, with a gVisor comparison*.

One EKS cluster, one instance type (`m8i.xlarge`), three isolation runtimes side by side: plain runc, [gVisor](https://gvisor.dev) `runsc`, and [AWS Nitro Sandboxes](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing.html). The article drafts with the benchmark numbers live in this repo: [`ARTICLE.md`](ARTICLE.md) (English) and [`ARTICLE-UK.md`](ARTICLE-UK.md) (Ukrainian).

## What is inside

| File | What it does |
|---|---|
| `vpc-default.tf` | Two private subnets inside the default VPC + a NAT gateway (no public IPs on nodes) |
| `cluster.tf` | EKS Auto Mode cluster (K8s `1.36`, required by Nitro Sandboxes), IAM, add-ons |
| `00-nodepool-nitro.yaml` | Auto Mode NodePool pinned to `m8i` with the `sandbox=nitro` taint |
| `01-runtimeclass-gvisor.yaml` | RuntimeClass `gvisor` scheduling to the gVisor node group |
| `gvisor-nodegroup.tf` | Managed node group for gVisor (shared `mng_node` IAM with microVM) |
| `gvisor.mime` | NodeConfig (`runsc` in containerd) + pinned gVisor install on node boot |
| `microvm-nodegroup.tf` | microVM pool (nested virtualization, Firecracker path) |
| `kvm-check.yaml` | DaemonSet printing `kvm=yes/no` per runtime |
| `10-smoke-tests.yaml` | Four probe pods: kernel and network checks per runtime |
| `30-agent-codeexec.yaml` | The agent pattern: agent pod (network on) + code-exec pod (`network-isolated`), exchange via the API server |
| `20-benchmark.sh` | Cold-start and density benchmarks, results appended to `benchmark-results.csv` |
| `evidence/` | Raw outputs from the live run: kernels per runtime, node tables, benchmark CSV |

## Quick start

```bash
aws sts get-caller-identity          # pick the account
terraform init && terraform apply    # ~20 min: VPC + cluster + node groups
aws eks update-kubeconfig --name agents-sandbox

kubectl apply -f 00-nodepool-nitro.yaml -f 01-runtimeclass-gvisor.yaml
kubectl apply -f 10-smoke-tests.yaml                 # isolation evidence
kubectl apply -f 30-agent-codeexec.yaml              # the agent pattern, demo mode

./20-benchmark.sh coldstart                          # N=10 pods per runtime
./20-benchmark.sh density                            # MAX=60 pods per runtime
./20-benchmark.sh cleanup                            # removes bench-* namespaces
```

Requires `terraform >= 1.6`, `aws >= 6.0` provider (see `terraform.lock.hcl`), `kubectl`, `jq`.

## Notes learned the hard way

- gVisor releases now ship as a bundle (`gvisor.tar.zstd` + `gvisor-bin/` sidecars); the old `release/latest/x86_64/runsc` URLs return 404. The install script in `gvisor.mime` pins `20261102.0` and installs the sidecar directory together with the binaries.
- The AL2023 EKS AMI ships containerd 2.x **without** a `runsc` runtime entry; the NodeConfig in `gvisor.mime` provides it. A node without it fails with `no runtime for runsc is configured`.
- On a fresh account the EC2 on-demand family vCPU limit is 32. Seven `m8i.xlarge` nodes already fill it; raise the limit or delete idle nodeclaims before density runs.
- Density packing follows CPU *requests*: with a full 1-vCPU request the sandbox slot budget (5× vCPU per node) never binds. The benchmark uses a 250m request with a 1-vCPU limit.
- Tear the stack down after the run: NAT and the EKS control plane bill per hour regardless of traffic (`terraform destroy`).

## Author

Igor Gorovyy, DevOps Engineer Lead & Senior Solutions Architect, AWS Community Builder — [LinkedIn](https://www.linkedin.com/in/gorovyyigor/)
