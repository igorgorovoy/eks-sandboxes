# eks-sandboxes

A working demo for the article *Running AI-generated code on EKS in Nitro Sandboxes: a hands-on guide*.

One EKS cluster, one instance type (`m8i.xlarge`), three isolation runtimes side by side: plain runc, [gVisor](https://gvisor.dev) `runsc`, and [AWS Nitro Sandboxes](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing.html). The article lives in this repo: [`article/ARTICLE.md`](article/ARTICLE.md) (English) and [`article/ARTICLE-UK.md`](article/ARTICLE-UK.md) (Ukrainian), PDFs in [`article/exports/`](article/exports/).

## Layout

```
article/    the article (EN, UK), working plan, PDF exports
terraform/  VPC, EKS Auto Mode cluster, node groups, gVisor node bootstrap
k8s/        NodePool, RuntimeClass, smoke tests, the agent pattern
scripts/    benchmark script, Markdown-to-PDF build
data/       benchmark results and raw evidence from the live run
```

## What is inside

| File | What it does |
|---|---|
| `terraform/vpc-default.tf` | Two private subnets inside the default VPC + a NAT gateway (no public IPs on nodes) |
| `terraform/cluster.tf` | EKS Auto Mode cluster (K8s `1.36`, required by Nitro Sandboxes), IAM, add-ons |
| `terraform/gvisor-nodegroup.tf` | Managed node group for gVisor (shared `mng_node` IAM with microVM) |
| `terraform/gvisor.mime` | NodeConfig (`runsc` in containerd) + pinned gVisor install on node boot |
| `terraform/microvm-nodegroup.tf` | microVM pool (nested virtualization, Firecracker path) |
| `k8s/00-nodepool-nitro.yaml` | Auto Mode NodePool pinned to `m8i` with the `sandbox=nitro` taint |
| `k8s/01-runtimeclass-gvisor.yaml` | RuntimeClass `gvisor` scheduling to the gVisor node group |
| `k8s/10-smoke-tests.yaml` | Four probe pods: kernel and network checks per runtime |
| `k8s/30-agent-codeexec.yaml` | The agent pattern: agent pod (network on) + code-exec pod (`network-isolated`), exchange via the API server |
| `k8s/kvm-check.yaml` | DaemonSet printing `kvm=yes/no` per runtime |
| `scripts/20-benchmark.sh` | Cold-start and density benchmarks, results appended to `data/benchmark-results.csv` |
| `scripts/build_pdf.py` | Markdown + mermaid to styled PDF (mermaid-cli, pandoc, headless Chrome) |
| `data/benchmark-results.csv` | Second benchmark run (warm nodes) and density runs |
| `data/bench-pass1-raw.csv` | First benchmark run (includes node bootstrap) |
| `data/evidence/` | Raw outputs from the live run: kernels per runtime, node tables, an earlier CSV snapshot |

## Quick start

```bash
aws sts get-caller-identity                          # pick the account
cd terraform && terraform init && terraform apply    # ~20 min: VPC + cluster + node groups
cd ..
aws eks update-kubeconfig --name agents-sandbox

kubectl apply -f k8s/00-nodepool-nitro.yaml -f k8s/01-runtimeclass-gvisor.yaml
kubectl apply -f k8s/10-smoke-tests.yaml             # isolation evidence
kubectl apply -f k8s/30-agent-codeexec.yaml          # the agent pattern, demo mode

./scripts/20-benchmark.sh coldstart                  # N=10 pods per runtime
./scripts/20-benchmark.sh density                    # MAX=60 pods per runtime
./scripts/20-benchmark.sh cleanup                    # removes bench-* namespaces

python3 scripts/build_pdf.py article/ARTICLE.md article/ARTICLE-UK.md   # PDFs next to the sources
```

Requires `terraform >= 1.6`, `aws >= 6.0` provider (see `terraform/.terraform.lock.hcl`), `kubectl`, `jq`.

## Notes learned the hard way

- gVisor releases now ship as a bundle (`gvisor.tar.zstd` + `gvisor-bin/` sidecars); the old `release/latest/x86_64/runsc` URLs return 404. The install script in `terraform/gvisor.mime` pins `20261102.0` and installs the sidecar directory together with the binaries.
- The AL2023 EKS AMI ships containerd 2.x **without** a `runsc` runtime entry; the NodeConfig in `terraform/gvisor.mime` provides it. A node without it fails with `no runtime for runsc is configured`.
- On a fresh account the EC2 on-demand family vCPU limit is 32. Seven `m8i.xlarge` nodes already fill it; raise the limit or delete idle nodeclaims before density runs.
- Density packing follows CPU *requests*: with a full 1-vCPU request the sandbox slot budget (5× vCPU per node) never binds. The benchmark uses a 250m request with a 1-vCPU limit.
- Tear the stack down after the run: NAT and the EKS control plane bill per hour regardless of traffic (`terraform destroy` in `terraform/`).

## Author

Igor Gorovyy, DevOps Engineer Lead & Senior Solutions Architect, AWS Community Builder — [LinkedIn](https://www.linkedin.com/in/gorovyyigor/)
