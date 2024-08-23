#!/bin/bash
set -euo pipefail

# see https://github.com/siderolabs/talos/releases
# renovate: datasource=github-releases depName=siderolabs/talos
talos_version="1.7.6"

# see https://github.com/siderolabs/extensions/pkgs/container/qemu-guest-agent
# see https://github.com/siderolabs/extensions/tree/main/guest-agents/qemu-guest-agent
talos_qemu_guest_agent_extension_tag="8.2.2@sha256:e8020f513f891896fd3bb506c7af8a763a3c70b063e4901caaad073b5e6e0815"

# see https://github.com/siderolabs/extensions/pkgs/container/drbd
# see https://github.com/siderolabs/extensions/tree/main/storage/drbd
# see https://github.com/LINBIT/drbd
talos_drbd_extension_tag="9.2.8-v1.7.6@sha256:acd871c1367ce94121689d069fd563c54ca0edac8698325f34a41dd3456eceea"

# see https://github.com/siderolabs/extensions/pkgs/container/spin
# see https://github.com/siderolabs/extensions/tree/main/container-runtime/spin
talos_spin_extension_tag="v0.15.0@sha256:0ec7613913960c95413699a46745a788d4c22776942c2d24ebd0457f11e6be33"

# see https://github.com/piraeusdatastore/piraeus-operator/releases
# renovate: datasource=github-releases depName=piraeusdatastore/piraeus-operator
piraeus_operator_version="2.5.2"

export CHECKPOINT_DISABLE='1'
export TF_LOG='DEBUG' # TRACE, DEBUG, INFO, WARN or ERROR.
export TF_LOG_PATH='terraform.log'

export TALOSCONFIG=$PWD/talosconfig.yml
export KUBECONFIG=$PWD/kubeconfig.yml

# FIX ME do something more elegant using the tf ingress_domain variable
export DOMAIN=${DOMAIN:-example.com}

function step {
  echo "### $* ###"
}

function update-talos-extension {
  # see https://github.com/siderolabs/extensions?tab=readme-ov-file#installing-extensions
  local variable_name="$1"
  local image_name="$2"
  local images="$3"
  local image="$(grep -F "$image_name:" <<<"$images")"
  local tag="${image#*:}"
  echo "updating the talos extension to $image..."
  variable_name="$variable_name" tag="$tag" perl -i -pe '
    BEGIN {
      $var = $ENV{variable_name};
      $val = $ENV{tag};
    }
    s/^(\Q$var\E=).*/$1"$val"/;
  ' do
}

function update-talos-extensions {
  step "updating the talos extensions"
  local images="$(crane export "ghcr.io/siderolabs/extensions:v$talos_version" | tar x -O image-digests)"
  update-talos-extension talos_qemu_guest_agent_extension_tag ghcr.io/siderolabs/qemu-guest-agent "$images"
  update-talos-extension talos_drbd_extension_tag ghcr.io/siderolabs/drbd "$images"
  update-talos-extension talos_spin_extension_tag ghcr.io/siderolabs/spin "$images"
}

function build_talos_image {
  # see https://www.talos.dev/v1.7/talos-guides/install/boot-assets/
  # see https://www.talos.dev/v1.7/advanced/metal-network-configuration/
  # see Profile type at https://github.com/siderolabs/talos/blob/v1.7.6/pkg/imager/profile/profile.go#L22-L45
  local talos_version_tag="v$talos_version"
  rm -rf tmp/talos
  mkdir -p tmp/talos
  cat >"tmp/talos/talos-$talos_version.yml" <<EOF
arch: amd64
platform: nocloud
secureboot: false
version: $talos_version_tag
customization:
  extraKernelArgs:
    - net.ifnames=0
input:
  kernel:
    path: /usr/install/amd64/vmlinuz
  initramfs:
    path: /usr/install/amd64/initramfs.xz
  baseInstaller:
    imageRef: ghcr.io/siderolabs/installer:$talos_version_tag
  systemExtensions:
    - imageRef: ghcr.io/siderolabs/qemu-guest-agent:$talos_qemu_guest_agent_extension_tag
    # - imageRef: ghcr.io/siderolabs/drbd:$talos_drbd_extension_tag
    # - imageRef: ghcr.io/siderolabs/spin:$talos_spin_extension_tag
output:
  kind: image
  imageOptions:
    diskSize: $((2*1024*1024*1024))
    diskFormat: raw
  outFormat: raw
EOF
  local talos_libvirt_base_volume_name="talos-$talos_version.qcow2"
  docker run --rm -i \
    -v $PWD/tmp/talos:/secureboot:ro \
    -v $PWD/tmp/talos:/out \
    -v /dev:/dev \
    --privileged \
    "ghcr.io/siderolabs/imager:$talos_version_tag" \
    - < "tmp/talos/talos-$talos_version.yml"
  qemu-img convert -O qcow2 tmp/talos/nocloud-amd64.raw tmp/talos/$talos_libvirt_base_volume_name
  qemu-img info tmp/talos/$talos_libvirt_base_volume_name
  if [ -n "$(virsh vol-list default | grep $talos_libvirt_base_volume_name)" ]; then
    virsh vol-delete --pool default $talos_libvirt_base_volume_name
  fi
  virsh vol-create-as default $talos_libvirt_base_volume_name 10M
  virsh vol-upload --pool default $talos_libvirt_base_volume_name tmp/talos/$talos_libvirt_base_volume_name
  cat >terraform.tfvars <<EOF
talos_version                  = "$talos_version"
talos_libvirt_base_volume_name = "$talos_libvirt_base_volume_name"
EOF
}

function init {
  step 'build talos image'
  build_talos_image
  step 'terraform init'
  terraform init -lockfile=readonly
}

function plan {
  step 'terraform plan'
  terraform plan -out=tfplan
}

function apply {
  step 'terraform apply'
  terraform apply tfplan
  terraform output -raw talosconfig >talosconfig.yml
  terraform output -raw kubeconfig >kubeconfig.yml
  health
  local-path-storage-install
  cluster-apps-install
  info
}

function health {
  step 'talosctl health'
  local controllers="$(terraform output -raw controllers)"
  local workers="$(terraform output -raw workers)"
  local c0="$(echo $controllers | cut -d , -f 1)"
  talosctl -e $c0 -n $c0 \
    health \
    --control-plane-nodes $controllers \
    --worker-nodes $workers
}

function local-path-storage-install {
  step 'local-path-storage install'
  kubectl apply --server-side -k local-path-storage
}

function cluster-apps-install {
  step 'argo cd install'
  sed "s/example.com/$DOMAIN/g" argocd-values.yaml > tmp/argocd-values.yaml
  helm install argocd argo/argo-cd --create-namespace -n argocd -f tmp/argocd-values.yaml
  start_time="$(date +%s)"
  while ! kubectl get deployment argocd-server -n argocd &>/dev/null; do
    if [[ $(($(date +%s) - $start_time)) -ge 300 ]]; then
      echo "Error: ArgoCD is still missing after 5m of waiting."
      exit 1
    fi
    sleep 5
  done
  kubectl wait deployment --selector=app.kubernetes.io/instance=argocd \
      --for=condition=available --namespace=argocd --timeout 15m
  step 'secrets provisioning'
  kubectl apply -f files/argocd-repo-creds-k8s-apps-secret.yaml
  kubectl create ns cert-manager
  kubectl apply -f files/cloudflare-api-token.yaml

  step 'cluster apps install'
  sed "s/example.com/$DOMAIN/g" argocd-app-of-apps.yaml | kubectl apply -f /dev/stdin

}

function info {
  local controllers="$(terraform output -raw controllers)"
  local workers="$(terraform output -raw workers)"
  local nodes=($(echo "$controllers,$workers" | tr ',' ' '))
  step 'talos node installer image'
  for n in "${nodes[@]}"; do
    # NB there can be multiple machineconfigs in a machine. we only want to see
    #    the ones with an id that looks like a version tag.
    talosctl -n $n get machineconfigs -o json \
      | jq -r 'select(.metadata.id | test("v\\d+")) | .spec.machine.install.image' \
      | sed -E "s,(.+),$n: \1,g"
  done
  step 'talos node os-release'
  for n in "${nodes[@]}"; do
    talosctl -n $n read /etc/os-release \
      | sed -E "s,(.+),$n: \1,g"
  done
  step 'kubernetes nodes'
  kubectl get nodes -o wide
  # piraeus-info
}

function upgrade {
  step 'talosctl upgrade'
  local controllers=($(terraform output -raw controllers | tr ',' ' '))
  local workers=($(terraform output -raw workers | tr ',' ' '))
  for n in "${controllers[@]}" "${workers[@]}"; do
    talosctl -e $n -n $n upgrade --preserve --wait
  done
  health
}

function destroy {
  terraform destroy -auto-approve
}

case $1 in
  update-talos-extensions)
    update-talos-extensions
    ;;
  init)
    init
    ;;
  plan)
    plan
    ;;
  apply)
    apply
    ;;
  plan-apply)
    plan
    apply
    ;;
  health)
    health
    ;;
  info)
    info
    ;;
  destroy)
    destroy
    ;;
  *)
    echo $"Usage: $0 {init|plan|apply|plan-apply|health|info}"
    exit 1
    ;;
esac
