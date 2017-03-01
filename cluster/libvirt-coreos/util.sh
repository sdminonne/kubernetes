#!/bin/bash

# Copyright 2014 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# A library of helper functions that each provider hosting Kubernetes must implement to use cluster/kube-*.sh scripts.

[ ! -z ${UTIL_SH_DEBUG+x} ] && set -x

command -v kubectl >/dev/null 2>&1 || { echo >&2 "kubectl not found in path. Aborting."; exit 1; }

KUBE_ROOT=$(dirname "${BASH_SOURCE}")/../..
readonly ROOT=$(dirname "${BASH_SOURCE}")
source "$ROOT/${KUBE_CONFIG_FILE:-"config-default.sh"}"
source "$KUBE_ROOT/cluster/common.sh"
source "${KUBE_ROOT}/hack/lib/init.sh"

kube::util::test_openssl_installed
kube::util::test_cfssl_installed

export LIBVIRT_DEFAULT_URI=qemu:///system
export SERVICE_ACCOUNT_LOOKUP=${SERVICE_ACCOUNT_LOOKUP:-true}
export ADMISSION_CONTROL=${ADMISSION_CONTROL:-Initializers,NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,DefaultTolerationSeconds,ResourceQuota}
readonly POOL=kubernetes
readonly POOL_PATH=/var/lib/libvirt/images/kubernetes

[ ! -d "${POOL_PATH}" ] && (echo "$POOL_PATH" does not exist ; exit 1 )

# Creates a kubeconfig file for the kubelet.
# Args: address (e.g. "http://localhost:8080"), destination file path
function create-kubelet-kubeconfig() {
  local apiserver_address="${1}"
  local destination="${2}"
  if [[ -z "${apiserver_address}" ]]; then
    echo "Must provide API server address to create Kubelet kubeconfig file!"
    exit 1
  fi
  if [[ -z "${destination}" ]]; then
    echo "Must provide destination path to create Kubelet kubeconfig file!"
    exit 1
  fi
  echo "Creating Kubelet kubeconfig file"
  local dest_dir="$(dirname "${destination}")"
  mkdir -p "${dest_dir}" &>/dev/null || sudo mkdir -p "${dest_dir}"
  sudo=$(test -w "${dest_dir}" || echo "sudo -E")
  cat <<EOF | ${sudo} tee "${destination}" > /dev/null
apiVersion: v1
kind: Config
clusters:
  - cluster:
      server: ${apiserver_address}
    name: local
contexts:
  - context:
      cluster: local
    name: local
current-context: local
EOF
}

# join <delim> <list...>
# Concatenates the list elements with the delimiter passed as first parameter
#
# Ex: join , a b c
#  -> a,b,c
function join {
  local IFS="$1"
  shift
  echo "$*"
}

# Must ensure that the following ENV vars are set
function detect-master {
  KUBE_MASTER_IP=$MASTER_IP
  KUBE_MASTER=$MASTER_NAME
  export KUBERNETES_MASTER=http://$KUBE_MASTER_IP:8080
  echo "KUBE_MASTER_IP: $KUBE_MASTER_IP"
  echo "KUBE_MASTER: $KUBE_MASTER"
}

# Get node IP addresses and store in KUBE_NODE_IP_ADDRESSES[]
function detect-nodes {
  KUBE_NODE_IP_ADDRESSES=("${NODE_IPS[@]}")
}

export tempdir=$(mktemp -d)

readonly SERVER_CA_CRT="server-ca.crt"
readonly CLIENT_CA_CRT="client-ca.crt"
readonly SERVING_KUBE_APISERVER_CRT="serving-kube-apiserver.crt"
readonly SERVING_KUBE_APISERVER_KEY="serving-kube-apiserver.key"
readonly REQUEST_HEADER_CRT="request-header-ca.crt"

function generate_certs {

   echo "GENERATE certs -> ${tempdir}"
   mkdir -p  "$POOL_PATH/kubernetes/certs"
   kube::util::create_signing_certkey "" "$tempdir" server '"server auth"'
   cp ${tempdir}/${SERVER_CA_CRT} "$POOL_PATH/kubernetes/certs"

   kube::util::create_signing_certkey "" "${tempdir}" client '"client auth"'
   cp ${tempdir}/${CLIENT_CA_CRT} "$POOL_PATH/kubernetes/certs"

   SERVICE_ACCOUNT_KEY_FILE=${SERVICE_ACCOUNT_KEY_FILE:-kube-serviceaccount.key}
   openssl genrsa -out "$tempdir/${SERVICE_ACCOUNT_KEY_FILE}" 2048 2>/dev/null
   cp "${tempdir}/${SERVICE_ACCOUNT_KEY_FILE}" "$POOL_PATH/kubernetes/certs"

   kube::util::create_serving_certkey "" "${tempdir}" "server-ca" kube-apiserver kubernetes kubernetes.default kubernetes.default.svc  "localhost" ${MASTER_IP} ${MASTER_NAME} ${SERVICE_CLUSTER_IP_RANGE%.*}.1
   cp "${tempdir}/${SERVING_KUBE_APISERVER_CRT}" "$POOL_PATH/kubernetes/certs"
   chmod 666 "${tempdir}/${SERVING_KUBE_APISERVER_KEY}"
   cp "${tempdir}/${SERVING_KUBE_APISERVER_KEY}" "$POOL_PATH/kubernetes/certs"


   kube::util::create_signing_certkey "" "${tempdir}" request-header '"client auth"'
   cp "${tempdir}/${REQUEST_HEADER_CRT}" "$POOL_PATH/kubernetes/certs"

   # Create client certs signed with client-ca, given id, given CN and a number of groups
   kube::util::create_client_certkey "" "${tempdir}" 'client-ca' kube-proxy system:kube-proxy system:nodes
   kube::util::create_client_certkey "" "${tempdir}" 'client-ca' controller system:kube-controller-manager
   kube::util::create_client_certkey "" "${tempdir}" 'client-ca' scheduler  system:kube-scheduler
   kube::util::create_client_certkey "" "${tempdir}" 'client-ca' admin system:admin system:masters

}



#Setup registry proxy
function setup_registry_proxy {
  if [[ "$ENABLE_CLUSTER_REGISTRY" == "true" ]]; then
    cp "./cluster/saltbase/salt/kube-registry-proxy/kube-registry-proxy.yaml" "$POOL_PATH/kubernetes/manifests"
  fi
}

# Verify prereqs on host machine
function verify-prereqs {
  if ! which virsh >/dev/null; then
      echo "Can't find virsh in PATH, please fix and retry." >&2
      exit 1
  fi
  if ! virsh nodeinfo >/dev/null; then
      exit 1
  fi
  if [[ "$(</sys/kernel/mm/ksm/run)" -ne "1" ]]; then
      echo "KSM is not enabled" >&2
      echo "Enabling it would reduce the memory footprint of large clusters" >&2
      if [[ -t 0 ]]; then
          read -t 5 -n 1 -p "Do you want to enable KSM (requires root password) (y/n)? " answer
          echo ""
          if [[ "$answer" == 'y' ]]; then
              su -c 'echo 1 > /sys/kernel/mm/ksm/run'
          fi
      else
        echo "You can enable it with (as root):" >&2
        echo "" >&2
        echo "  echo 1 > /sys/kernel/mm/ksm/run" >&2
        echo "" >&2
      fi
  fi
}

# Destroy the libvirt storage pool and all the images inside
#
# If 'keep_base_image' is passed as first parameter,
# the base image is kept, as well as the storage pool.
# All the other images are deleted.
function destroy-pool {
  virsh pool-info $POOL >/dev/null 2>&1 || return

  rm -rf "$POOL_PATH"/kubernetes/*
  rm -rf "$POOL_PATH"/kubernetes_config*/*
  rm -rf "$POOL_PATH"/kubernetes_kubernetes*/*

  local vol
  virsh vol-list $POOL | awk 'NR>2 && !/^$/ && $1 ~ /^kubernetes/ {print $1}' | \
      while read vol; do
        virsh vol-delete $vol --pool $POOL
      done

  [[ "$1" == 'keep_base_image' ]] && return

  set +e
  virsh vol-delete coreos_base.img --pool $POOL
  virsh pool-destroy $POOL
  rmdir "$POOL_PATH"
  set -e
}

# Creates the libvirt storage pool and populate it with
# - the CoreOS base image
# - the kubernetes binaries
function initialize-pool {
  echo "Creating POOL_PATH at $POOL_PATH"
  mkdir -p "$POOL_PATH"
  if ! virsh pool-info $POOL >/dev/null 2>&1; then
      virsh pool-create-as $POOL dir --target "$POOL_PATH"
  fi

  wget -N -P "$ROOT" https://${COREOS_CHANNEL:-alpha}.release.core-os.net/amd64-usr/current/coreos_production_qemu_image.img.bz2
  if [[ "$ROOT/coreos_production_qemu_image.img.bz2" -nt "$POOL_PATH/coreos_base.img" ]]; then
      bunzip2 -f -k "$ROOT/coreos_production_qemu_image.img.bz2"
      virsh vol-delete coreos_base.img --pool $POOL 2> /dev/null || true
  fi
  if ! virsh vol-list $POOL | grep -q coreos_base.img; then
      virsh vol-create-as $POOL coreos_base.img 10G --format qcow2
      virsh vol-upload coreos_base.img "$ROOT/coreos_production_qemu_image.img" --pool $POOL
  fi

  mkdir -p "$POOL_PATH/kubernetes"
  kube-push-internal

  mkdir -p "$POOL_PATH/kubernetes/manifests"
  if [[ "$ENABLE_NODE_LOGGING" == "true" ]]; then
      if [[ "$LOGGING_DESTINATION" == "elasticsearch" ]]; then
          cp "$KUBE_ROOT/cluster/saltbase/salt/fluentd-es/fluentd-es.manifest" "$POOL_PATH/kubernetes/manifests"
      elif [[ "$LOGGING_DESTINATION" == "gcp" ]]; then
          cp "$KUBE_ROOT/cluster/saltbase/salt/fluentd-gcp/fluentd-gcp.manifest" "$POOL_PATH/kubernetes/manifests"
      fi
  fi


  virsh pool-refresh $POOL
}

function destroy-network {
  set +e
  virsh net-destroy kubernetes_global
  virsh net-destroy kubernetes_pods
  set -e
}

function initialize-network {
  virsh net-create "$ROOT/network_kubernetes_global.xml"
  virsh net-create "$ROOT/network_kubernetes_pods.xml"
}

function render-template {
  eval "echo \"$(cat $1)\""
}

function wait-cluster-readiness {
  echo "Wait for cluster readiness"

  local timeout=120
  while [[ $timeout -ne 0 ]]; do
    nb_ready_nodes=$(kubectl get nodes -o go-template="{{range.items}}{{range.status.conditions}}{{.type}}{{end}}:{{end}}" 2>/dev/null | tr ':' '\n' | grep -c Ready || true)
    echo "Nb ready nodes: $nb_ready_nodes / $NUM_NODES"
    if [[ "$nb_ready_nodes" -eq "$NUM_NODES" ]]; then
      return 0
    fi

    timeout=$(($timeout-1))
    sleep .5
  done

  return 1
}



#Master contains apiserver and etcd.
#It does not contain the scheduler and the controller manager
#Needs API_HOST_IP
#Needs ETCD_PORT
#Needs MASTER_NAME
function start_api_server {
  #TODO: @sdminonne port to etcd3
  #Using .../hack/lib/etcd.sh

  readonly ssh_keys="$(cat ~/.ssh/*.pub | sed 's/^/  - /')"

  ETCD_PORT=${ETCD_PORT:-2379}
  ETCD_PEER_PORT=${ETC_PEER_PORT:-2380}
  api_host_ip=${MASTER_IP:-192.168.10.1}
  apiserver_name=${MASTER_NAME:-apiserver}
  readonly kubernetes_dir="$POOL_PATH/kubernetes"
  mkdir -p ${kubernetes_dir}/bin
  mkdir -p ${kubernetes_dir}/certs
  mkdir -p ${kubernetes_dir}/config
  cp ${KUBE_ROOT}/_output/local/go/bin/kube-apiserver ${kubernetes_dir}/bin

  #TODO: @sdminonne port to etcd3
  #Using .../hack/lib/etcd.sh
  etcd2_initial_cluster="${apiserver_name}=http://${MASTER_IP}:${ETCD_PEER_PORT}"
  type=master
  name=${apiserver_name}
  public_ip=${api_host_ip}
  memory=2048
  image=$name.img
  config=kubernetes_config_$type
  virsh vol-create-as $POOL $image 10G --format qcow2 --backing-vol coreos_base.img --backing-vol-format qcow2

  mkdir -p "$POOL_PATH/$config/openstack/latest"
  render-template "$ROOT/user_data_master.yml" > "$POOL_PATH/$config/openstack/latest/user_data"
  virsh pool-refresh $POOL

  domain_xml=$(mktemp)
  render-template $ROOT/coreos.xml > $domain_xml
  virsh create $domain_xml
  rm $domain_xml

  kube::util::wait_for_url "http://${MASTER_IP}:${ETCD_PORT}/v2/machines" "etcd: " 0.25 4000
  curl -fs -X PUT "http://${MASTER_IP}:${ETCD_PORT}/v2/keys/_test"


}

function start_controller_and_scheduler {
  ssh-to-node "$MASTER_NAME" "sudo systemctl start kube-controller-manager kube-scheduler"
}

function message_ok {
  txt=$1
  printf "${GREEN}$txt${NC}\n"
}

function kube-up {
  detect-master
  detect-nodes
  initialize-pool keep_base_image
  generate_certs "${NODE_NAMES[@]}"
  setup_registry_proxy
  initialize-network

  start_api_server

  readonly wait_for_url_api_srever=30
  kube::util::wait_for_url "http://${MASTER_IP}:8080/version" "apiserver: " 1 ${wait_for_url_api_srever}
  message_ok "k8s API server up and running"

  configure-kubectl
  message_ok "kubectl configured"


  kube::util::write_client_kubeconfig "" "${tempdir}" "${SERVER_CA_CRT}" "${MASTER_NAME}" "6443" controller
  cp "${tempdir}/controller.kubeconfig" "$POOL_PATH/kubernetes/config"
  kube::util::write_client_kubeconfig "" "${tempdir}" "${SERVER_CA_CRT}" "${MASTER_NAME}" "6443" scheduler
  cp "${tempdir}/scheduler.kubeconfig" "$POOL_PATH/kubernetes/config"
  start_controller_and_scheduler

  message_ok "controller and scheduler started"
  node_names=("${NODE_NAMES[@]}")

  for (( i = 0 ; i < $NUM_NODES ; i++ )); do
    type=node-$(printf "%02d" $i)
    name="${NODE_NAMES[i]}"
    public_ip=${NODE_IPS[$i]}
    memory=1024
    image=$name.img
    config=kubernetes_config_$type

    virsh vol-create-as $POOL $image 10G --format qcow2 --backing-vol coreos_base.img --backing-vol-format qcow2

    mkdir -p "$POOL_PATH/$config/openstack/latest"
    render-template "$ROOT/user_data_node.yml" > "$POOL_PATH/$config/openstack/latest/user_data"

    kube::util::create_client_certkey "" "${tempdir}" 'client-ca' "${NODE_NAMES[$i]}-kubelet" system:node:${NODE_NAMES[$i]} system:nodes
    kube::util::write_client_kubeconfig "" "${tempdir}" "${SERVER_CA_CRT}" "${MASTER_IP}" "6443" "${NODE_NAMES[$i]}-kubelet"
    mv "$tempdir/${NODE_NAMES[$i]}-kubelet.kubeconfig" "$POOL_PATH/kubernetes/config"

    kube::util::create_client_certkey "" "${tempdir}" 'client-ca' "${NODE_NAMES[$i]}-kube-proxy" system:kube-proxy system:nodes
    kube::util::write_client_kubeconfig "" "${tempdir}" "${SERVER_CA_CRT}" "${MASTER_IP}" "6443" "${NODE_NAMES[$i]}-kube-proxy"
    mv "$tempdir/${NODE_NAMES[$i]}-kube-proxy.kubeconfig" "$POOL_PATH/kubernetes/config"

    virsh pool-refresh $POOL

    domain_xml=$(mktemp)
    render-template $ROOT/coreos.xml > $domain_xml
    virsh create $domain_xml
  done

  wait-kube-system
  start_kubedns
  start-registry
  create-kubelet-kubeconfig "http://${MASTER_IP}:8080" "${POOL_PATH}/kubernetes/kubeconfig/kubelet.kubeconfig"

}


function start_kubedns {
  if [[ "${ENABLE_CLUSTER_DNS}" != "true" ]]; then
    return 0
  fi
  sed -f "${KUBE_ROOT}/cluster/addons/dns/transforms2sed.sed" < "${KUBE_ROOT}/cluster/addons/dns/kubedns-controller.yaml.base" | sed -f "${KUBE_ROOT}/cluster/libvirt-coreos/forShellEval.sed"  > "${KUBE_ROOT}/cluster/libvirt-coreos/kubedns-controller.yaml.tmp"
  sed -f "${KUBE_ROOT}/cluster/addons/dns/transforms2sed.sed" < "${KUBE_ROOT}/cluster/addons/dns/kubedns-svc.yaml.base" | sed -f "${KUBE_ROOT}/cluster/libvirt-coreos/forShellEval.sed"  > "${KUBE_ROOT}/cluster/libvirt-coreos/kubedns-svc.yaml.tmp"

  render-template "$ROOT/kubedns-svc.yaml.tmp" > "$ROOT/kubedns-svc.yaml"
  render-template "$ROOT/kubedns-controller.yaml.tmp"  > "$ROOT/kubedns-controller.yaml"

  echo "starting kubedns..."
  #kubectl create clusterrolebinding system:kube-dns --clusterrole=cluster-admin --serviceaccount=kube-system:default
  kubectl  --namespace=kube-system create -f "${KUBE_ROOT}/cluster/addons/dns/kubedns-sa.yaml"
  kubectl  --namespace=kube-system create -f "${KUBE_ROOT}/cluster/addons/dns/kubedns-cm.yaml"
  kubectl  --namespace=kube-system create -f "$ROOT/kubedns-controller.yaml"
  kubectl  --namespace=kube-system create -f "$ROOT/kubedns-svc.yaml"

  rm -rf "$ROOT/kubedns-controller.yaml" "$ROOT/kubedns-controller.yaml.tmp" "$ROOT/kubedns-svc.yaml" "$ROOT/kubedns-svc.yaml.tmp"

}


function configure-kubectl {
  kubectl config set-cluster default-cluster --server=https://${MASTER_IP}:6443 --certificate-authority="$tempdir/${SERVER_CA_CRT}"
  kubectl config set-credentials default-admin --certificate-authority="$tempdir/${SERVER_CA_CRT}" --client-key="$tempdir/client-admin.key" --client-certificate="$tempdir/client-admin.crt"
  kubectl config set-context default-system --cluster=default-cluster --user=default-admin
  kubectl config use-context default-system
}

function create_registry_rc() {
  echo " Create registry replication controller"
  sed -f "${KUBE_ROOT}/cluster/libvirt-coreos/forEmptyDirRegistry.sed" < "${KUBE_ROOT}/cluster/addons/registry/registry-rc.yaml"  > "${KUBE_ROOT}/cluster/libvirt-coreos/registry-rc.yaml"
  kubectl create -f "${KUBE_ROOT}/cluster/libvirt-coreos/registry-rc.yaml"
  local timeout=120
  while [[ $timeout -ne 0 ]]; do
    phase=$(kubectl get pods -n kube-system -lk8s-app=kube-registry --output='jsonpath={.items..status.phase}')
    if [ "$phase" = "Running" ]; then
      break
    fi
    timeout=$(($timeout-1))
    sleep .5
  done
  rm -rf "${KUBE_ROOT}/cluster/libvirt-coreos/registry-rc.yaml"
}

function create_registry_svc() {
  echo " Create registry service"
  kubectl create -f "${KUBE_ROOT}/cluster/addons/registry/registry-svc.yaml"
}

function create_registry_daemonset() {
  echo "Create registry daemonset"
  kubectl create -f "${KUBE_ROOT}/cluster/saltbase/salt/kube-registry-proxy/kube-registry-proxy.yaml"
  local timeout=120
  while [[ $timeout -ne 0 ]]; do
    desiredNumberScheduled=$(kubectl get daemonset kube-registry-proxy -n kube-system  -o='jsonpath={.items...status.currentNumberScheduled}')
    numberReady=$(kubectl get daemonset kube-registry-proxy -n kube-system  -o='jsonpath={.items...status.numberReady}')
    if [ $desiredNumberScheduled = $numberReady]; then
      echo "Registry daemonset ready"
      return 0
    fi
    echo "waiting for kube-registry-proxy on each node"
    timeout=$(($timeout-1))
    sleep .5
  done
}

function wait-kube-system() {
  local timeout=120
  while [[ $timeout -ne 0 ]]; do
    phase=$(kubectl get namespaces --output=jsonpath='{.items[?(@.metadata.name=="kube-system")].status.phase}')
    if [ "$phase" = "Active" ]; then
      message_ok "kube-system namespace ok"
      break
    fi
    echo "waiting for namespace kube-system"
    timeout=$(($timeout-1))
    sleep .5
  done
}

function start-registry() {
  if [[ "$ENABLE_CLUSTER_REGISTRY" != "true" ]]; then
    return 0
  fi

  echo "Create registry..."
  create_registry_svc
  create_registry_rc
  create_registry_daemonset

  message_ok "registry up&running"
}

# Delete a kubernetes cluster
function kube-down {
  virsh list | awk 'NR>2 && !/^$/ && $2 ~ /^kubernetes/ {print $2}' | \
      while read dom; do
        virsh destroy $dom
      done
  destroy-pool keep_base_image
  destroy-network
}

# The kubernetes binaries are pushed to a host directory which is exposed to the VM
function upload-server-tars {
  tar -x -C "$POOL_PATH/kubernetes" -f "$SERVER_BINARY_TAR" kubernetes
  rm -rf "$POOL_PATH/kubernetes/bin"
  mv "$POOL_PATH/kubernetes/kubernetes/server/bin" "$POOL_PATH/kubernetes/bin"
  chmod -R 755 "$POOL_PATH/kubernetes/bin"
  rm -fr "$POOL_PATH/kubernetes/kubernetes"
}

# Update a kubernetes cluster with latest source
function kube-push {
  kube-push-internal
  ssh-to-node "$MASTER_NAME" "sudo systemctl restart kube-apiserver kube-controller-manager kube-scheduler"
  for ((i=0; i < NUM_NODES; i++)); do
    ssh-to-node "${NODE_NAMES[$i]}" "sudo systemctl restart kubelet kube-proxy"
  done

  wait-cluster-readiness
}

function kube-push-internal {
  case "${KUBE_PUSH:-release}" in
    release)
      kube-push-release;;
    local)
      kube-push-local;;
    *)
      echo "The only known push methods are \"release\" to use the release tarball or \"local\" to use the binaries built by make. KUBE_PUSH is set \"$KUBE_PUSH\"" >&2
      return 1;;
  esac
}

function kube-push-release {
  find-release-tars
  upload-server-tars
}

function kube-push-local {
  rm -rf "$POOL_PATH/kubernetes/bin/*"
  mkdir -p "$POOL_PATH/kubernetes/bin"
  cp "${KUBE_ROOT}/_output/local/go/bin"/* "$POOL_PATH/kubernetes/bin"

}

# Execute prior to running tests to build a release if required for env
function test-build-release {
  echo "TODO"
}

# Execute prior to running tests to initialize required structure
function test-setup {
  "${KUBE_ROOT}/cluster/kube-up.sh"
}

# Execute after running tests to perform any required clean-up
function test-teardown {
  kube-down
}

# SSH to a node by name or IP ($1) and run a command ($2).
function ssh-to-node {
  local node="$1"
  local cmd="$2"
  local machine

  if [[ "$node" == "$MASTER_IP" ]] || [[ "$node" =~ ^"$NODE_IP_BASE" ]]; then
      machine="$node"
  elif [[ "$node" == "$MASTER_NAME" ]]; then
      machine="$MASTER_IP"
  else
    for ((i=0; i < NUM_NODES; i++)); do
        if [[ "$node" == "${NODE_NAMES[$i]}" ]]; then
            machine="${NODE_IPS[$i]}"
            break
        fi
    done
  fi
  if [[ -z "$machine" ]]; then
      echo "$node is an unknown machine to ssh to" >&2
  fi
  ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ControlMaster=no "core@$machine" "$cmd"
}

# Perform preparations required to run e2e tests
function prepare-e2e() {
    echo "libvirt-coreos doesn't need special preparations for e2e tests" 1>&2
}
