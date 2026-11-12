#!/usr/bin/env bash

set -e

variant=${1:-${VARIANT}}
deployment=${2:-${DEPLOYMENT_NAME}}
namespace=${3:-${NAMESPACE}}

[[ -z $namespace ]] && namespace="default"

path=$(dirname "$0")

timed() {
  end=$(date +%s)
  dt=$(($end - $1))
  dd=$(($dt / 86400))
  dt2=$(($dt - 86400 * $dd))
  dh=$(($dt2 / 3600))
  dt3=$(($dt2 - 3600 * $dh))
  dm=$(($dt3 / 60))
  ds=$(($dt3 - 60 * $dm))

  LC_NUMERIC=C printf "\nTotal runtime: %02d min %02d seconds\n" "$dm" "$ds"
}

success() {
  newman run \
    --delay-request=100 \
    --folder=success \
    --export-environment "$variant"/postman/environment.json \
    --environment "$variant"/postman/environment.json \
    "$variant"/postman/collection.json
}

step() {
  local step=$1 replicas pods
  [[ $((step % 2)) -eq 0 ]] && replicas=1 || replicas=0

  printf "=== Step %d: scale %s to %s ===\n" "$step" "$deployment" "$replicas"

  if [[ $replicas -eq 0 ]]; then
    pods=$(kubectl get pods -n "$namespace" -l "app.kubernetes.io/name=$deployment" -o name)
  fi

  kubectl scale deployment "$deployment" -n "$namespace" --replicas "$replicas"
  if [[ $replicas -eq 0 ]]; then
    payment_stopped=1
    if [[ -n $pods ]]; then
      mapfile -t pod_names <<< "$pods"
      kubectl wait -n "$namespace" --for=delete "${pod_names[@]}" --timeout=70s
    fi
  else
    kubectl rollout status deployment "$deployment" -n "$namespace" --timeout=80s
    payment_stopped=0
  fi

  newman run \
    --delay-request=100 \
    --folder=step"$step" \
    --export-environment "$variant"/postman/environment.json \
    --environment "$variant"/postman/environment.json \
    "$variant"/postman/collection.json

  printf "=== Step %d completed ===\n" "$step"
}

start=$(date +%s)
payment_stopped=0
cleanup() {
  if [[ $payment_stopped -eq 1 ]]; then
    kubectl scale deployment "$deployment" -n "$namespace" --replicas=1 ||
      printf 'Could not restore deployment %s\n' "$deployment" >&2
  fi
  timed "$start"
}
trap cleanup EXIT

printf "=== Start test scenario ===\n"

# success execute
success

# stop service
step 1

# start service
step 2

# stop service
step 3

# start service
step 4
