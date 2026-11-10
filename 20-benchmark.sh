#!/usr/bin/env bash
set -euo pipefail

# Бенчмарк для статті «Hardware-isolated AI agents on EKS with Nitro Sandboxes (vs gVisor)».
#
# Міряє:
#   coldstart — час від apply до Ready для N подів кожного рантайму (per-pod + wall time).
#               Перший прогін включає бутстрап ноди (Auto Mode / MNG) — прогін два рази,
#               другий вважай «теплим».
#   density   — скільки 1-vCPU подів реально влазить на ноду, доки решта не зависне в Pending.
#               На m8i.xlarge (4 vCPU) гіпотеза: Nitro Sandbox ліміт 5× vCPU => ~20 подів.
#               Скрипт міряє емпірично, а не за документацією.
#
# Результати дописуються у benchmark-results.csv: metric,runtime,subject,value
#
# Before run: terraform apply, kubectl apply -f 01-runtimeclass-gvisor.yaml,
# пройти smoke-тест (10-smoke-tests.yaml), зафіксувати версію gVisor у gvisor.mime.
#
# Використання:
#   ./20-benchmark.sh coldstart [runtime ...]
#   ./20-benchmark.sh density   [runtime ...]
#   ./20-benchmark.sh cleanup
# Runtimes: runc | nitro | nitro-net | gvisor (за замовчуванням усі)
# Env: N=10 (coldstart pods)  MAX=60 (density)  TIMEOUT=900  POLL_INTERVAL=2  CSV=benchmark-results.csv

IMAGE="public.ecr.aws/docker/library/busybox:1.36"
CPU="${CPU:-1}"
MEM="${MEM:-512Mi}"
CSV="${CSV:-benchmark-results.csv}"
TIMEOUT="${TIMEOUT:-900}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"

for bin in kubectl jq; do
  command -v "$bin" >/dev/null || { echo "потрібен $bin"; exit 1; }
done

usage() {
  grep '^#   \./20-benchmark' "$0" | sed 's/^# *//'
  exit 1
}

runtimes_from_args() {
  if [ $# -gt 0 ]; then printf '%s\n' "$@"; else printf 'runc\nnitro\nnitro-net\ngvisor\n'; fi
}

# emit_pod RT ID -> YAML одного пода на stdout
emit_pod() {
  local rt="$1" id="$2"
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: bench-%s-%s\n' "$rt" "$id"
  if [ "$rt" = "nitro-net" ]; then
    printf '  annotations:\n    sandbox.amazonaws.com/network-isolated: "true"\n'
  fi
  printf 'spec:\n'
  case "$rt" in
    nitro|nitro-net) printf '  runtimeClassName: isolated-sandbox\n' ;;
    gvisor)          printf '  runtimeClassName: gvisor\n' ;;
  esac
  case "$rt" in
    runc|nitro|nitro-net)
      # HTTP/TCP-проби не працюють у network-isolated пісочниці — тому проб немає в усіх,
      # щоб порівняння було однаковим.
      printf '  nodeSelector:\n    sandbox-runtime: nitro\n'
      printf '  tolerations:\n    - { key: sandbox, operator: Equal, value: nitro, effect: NoSchedule }\n'
      ;;
  esac
  printf '  containers:\n'
  printf '    - name: main\n      image: %s\n' "$IMAGE"
  printf '      command: ["sh", "-c", "sleep infinity"]\n'
  printf '      resources:\n'
  printf '        requests: { cpu: "%s", memory: %s }\n' "$CPU" "$MEM"
  printf '        limits:   { cpu: "%s", memory: %s }\n' "$CPU" "$MEM"
  printf -- '---\n'
}

gen_manifest() {
  local rt="$1" count="$2" i
  for ((i = 0; i < count; i++)); do emit_pod "$rt" "$i"; done
}

pod_counters() {
  # читає JSON з stdin: друкує "total ready"
  jq -r '
    .items as $items |
    ($items | length | tostring) as $total |
    ([$items[] |
      select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length | tostring) as $ready |
    "\($total) \($ready)"
  '
}

# Ready-час без наносекунд (jq fromdateiso8601 їх не парсить) — def підставляється в кожну jq-програму
JQ_TS_DEF='def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;'

coldstart_once() {
  local rt="$1" n="$2"
  local ns="bench-cs-$rt-$RANDOM-$RANDOM"
  local json t0 wall total ready nodes
  echo "[$rt] coldstart: ns=$ns pods=$n"
  kubectl create namespace "$ns" >/dev/null
  t0=$(date +%s)
  gen_manifest "$rt" "$n" | kubectl apply -n "$ns" -f - >/dev/null

  while :; do
    json=$(kubectl get pods -n "$ns" -o json)
    read -r total ready <<<"$(pod_counters <<<"$json")"
    [ "$ready" = "$total" ] && break
    if [ $(( $(date +%s) - t0 )) -ge "$TIMEOUT" ]; then
      echo "[$rt] TIMEOUT ${TIMEOUT}s: ready=$ready/$total (пишу те, що встигло)"
      break
    fi
    sleep "$POLL_INTERVAL"
  done
  wall=$(( $(date +%s) - t0 ))
  nodes=$(jq -r '[.items[].spec.nodeName // "unscheduled"] | unique | join(",")' <<<"$json")
  echo "[$rt] ready=$ready/$total wall=${wall}s nodes=[$nodes]"

  jq -r "$JQ_TS_DEF
    .items[] |
    [ .metadata.name,
      (.metadata.creationTimestamp | ts),
      ([.status.conditions[]? | select(.type == \"Ready\")]
        | (.[0].lastTransitionTime // null)
        | if . == null then -1 else ts end)
    ] | @tsv" <<<"$json" | while IFS=$'\t' read -r name created readyt; do
    printf 'coldstart,%s,%s,%s\n' "$rt" "$name" "$((readyt - created))" >>"$CSV"
  done
  printf 'coldstart,%s,WALL,%s\n'      "$rt" "$wall" >>"$CSV"
  printf 'coldstart,%s,NODES,%s\n'     "$rt" "$(jq -r '[.items[].spec.nodeName // "unscheduled"] | unique | length' <<<"$json")" >>"$CSV"
  kubectl delete namespace "$ns" --wait=false >/dev/null
}

coldstart() {
  local rt
  while read -r rt; do
    coldstart_once "$rt" "${N:-10}"
  done < <(runtimes_from_args "$@")
}

density_once() {
  local rt="$1" max="$2"
  local ns="bench-den-$rt-$RANDOM-$RANDOM"
  local json prev=-1 stable=0 ready total t0=0 nodes
  echo "[$rt] density: ns=$ns max=$max"
  kubectl create namespace "$ns" >/dev/null
  gen_manifest "$rt" "$max" | kubectl apply -n "$ns" -f - >/dev/null
  t0=$(date +%s)

  while :; do
    json=$(kubectl get pods -n "$ns" -o json)
    read -r total ready <<<"$(pod_counters <<<"$json")"
    if [ "$ready" = "$prev" ]; then
      stable=$((stable + 1))   # Ready не росте три підряд => плато, виносимо вердикт
    else
      stable=0; prev=$ready
    fi
    if [ "$stable" -ge 3 ] || [ $(( $(date +%s) - t0 )) -ge "$TIMEOUT" ]; then
      break
    fi
    sleep "$POLL_INTERVAL"
  done

  nodes=$(jq -r '.items[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="True")) | .spec.nodeName' <<<"$json" | sort | uniq -c | sort -rn)
  echo "[$rt] density: ready=$ready/$total; по нодам:"
  echo "$nodes"
  echo "$nodes" | awk -v rt="$rt" '{printf "density,%s,%s,%s\n", rt, $2, $1}' >>"$CSV"
  printf 'density,%s,TOTAL_READY,%s\n' "$rt" "$ready" >>"$CSV"
  printf 'density,%s,PENDING,%s\n'     "$rt" "$((total - ready))" >>"$CSV"
  kubectl delete namespace "$ns" --wait=false >/dev/null
}

density() {
  local rt
  while read -r rt; do
    density_once "$rt" "${MAX:-60}"
  done < <(runtimes_from_args "$@")
}

cleanup() {
  echo "видаляю namespaces bench-cs-* та bench-den-*..."
  kubectl get namespaces -o name | grep -E '^namespace/bench-(cs|den)-' | cut -d/ -f2 \
    | xargs -r kubectl delete namespace --wait=false
}

[ $# -ge 1 ] || usage
[ -f "$CSV" ] || echo "metric,runtime,subject,value" >"$CSV"

case "$1" in
  coldstart) shift; coldstart "$@" ;;
  density)   shift; density   "$@" ;;
  cleanup)   cleanup ;;
  *) usage ;;
esac

echo "результати: $CSV"
