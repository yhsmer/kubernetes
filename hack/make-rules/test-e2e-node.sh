#!/usr/bin/env bash

# Copyright 2016 The Kubernetes Authors.
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

KUBE_ROOT=$(dirname "${BASH_SOURCE[0]}")/../..
source "${KUBE_ROOT}/hack/lib/init.sh"

kube::golang::setup_env

# start the cache mutation detector by default so that cache mutators will be found
KUBE_CACHE_MUTATION_DETECTOR="${KUBE_CACHE_MUTATION_DETECTOR:-true}"
export KUBE_CACHE_MUTATION_DETECTOR

# panic the server on watch decode errors since they are considered coder mistakes
KUBE_PANIC_WATCH_DECODE_ERROR="${KUBE_PANIC_WATCH_DECODE_ERROR:-true}"
export KUBE_PANIC_WATCH_DECODE_ERROR

focus=${FOCUS:-""}
skip=${SKIP-"\[Flaky\]|\[Slow\]|\[Serial\]"}
# The number of tests that can run in parallel depends on what tests
# are running and on the size of the node. Too many, and tests will
# fail due to resource contention. 8 is a reasonable default for a
# n1-standard-1 node.
# Currently, parallelism only affects when REMOTE=true. For local test,
# ginkgo default parallelism (cores - 1) is used.
parallelism=${PARALLELISM:-8}
artifacts="${ARTIFACTS:-"/tmp/_artifacts/$(date +%y%m%dT%H%M%S)"}"
remote=${REMOTE:-"false"}
runtime=${RUNTIME:-"docker"}
container_runtime_endpoint=${CONTAINER_RUNTIME_ENDPOINT:-""}
image_service_endpoint=${IMAGE_SERVICE_ENDPOINT:-""}
run_until_failure=${RUN_UNTIL_FAILURE:-"false"}
test_args=${TEST_ARGS:-""}
timeout_arg=""
system_spec_name=${SYSTEM_SPEC_NAME:-}
extra_envs=${EXTRA_ENVS:-}
runtime_config=${RUNTIME_CONFIG:-}
ssh_user=${SSH_USER:-"${USER}"}
ssh_key=${SSH_KEY:-}

# Parse the flags to pass to ginkgo
ginkgoflags=""
if [[ ${parallelism} -gt 1 ]]; then
  ginkgoflags="${ginkgoflags} -nodes=${parallelism} "
fi

if [[ ${focus} != "" ]]; then
  ginkgoflags="${ginkgoflags} -focus=\"${focus}\" "
fi

if [[ ${skip} != "" ]]; then
  ginkgoflags="${ginkgoflags} -skip=\"${skip}\" "
fi

if [[ ${run_until_failure} != "" ]]; then
  ginkgoflags="${ginkgoflags} -untilItFails=${run_until_failure} "
fi

# Setup the directory to copy test artifacts (logs, junit.xml, etc) from remote host to local host
if [ ! -d "${artifacts}" ]; then
  echo "Creating artifacts directory at ${artifacts}"
  mkdir -p "${artifacts}"
fi
echo "Test artifacts will be written to ${artifacts}"

if [[ ${runtime} == "remote" ]] ; then
  if [[ -n ${container_runtime_endpoint} ]] ; then
    test_args="--container-runtime-endpoint=${container_runtime_endpoint} ${test_args}"
  fi
  if [[ -n ${image_service_endpoint} ]] ; then
    test_args="--image-service-endpoint=${image_service_endpoint} ${test_args}"
  fi
fi


if [ "${remote}" = true ] ; then
  # The following options are only valid in remote run.
  images=${IMAGES:-""}
  hosts=${HOSTS:-""}
  image_project=${IMAGE_PROJECT:-"kubernetes-node-e2e-images"}
  metadata=${INSTANCE_METADATA:-""}
  list_images=${LIST_IMAGES:-false}
  if  [[ ${list_images} == "true" ]]; then
    gcloud compute images list --project="${image_project}" | grep "e2e-node"
    exit 0
  fi
  gubernator=${GUBERNATOR:-"false"}
  image_config_file=${IMAGE_CONFIG_FILE:-""}
  if [[ ${hosts} == "" && ${images} == "" && ${image_config_file} == "" ]]; then
    image_project="${IMAGE_PROJECT:-"cos-cloud"}"
    gci_image=$(gcloud compute images list --project "${image_project}" \
    --no-standard-images --filter="name ~ 'cos-beta.*'" --format="table[no-heading](name)")
    images=${gci_image}
    metadata="user-data<${KUBE_ROOT}/test/e2e_node/jenkins/gci-init.yaml,gci-update-strategy=update_disabled"
  fi
  instance_prefix=${INSTANCE_PREFIX:-"test"}
  cleanup=${CLEANUP:-"true"}
  delete_instances=${DELETE_INSTANCES:-"false"}
  preemptible_instances=${PREEMPTIBLE_INSTANCES:-"false"}
  test_suite=${TEST_SUITE:-"default"}
  if [[ -n "${TIMEOUT:-}" ]] ; then
    timeout_arg="--test-timeout=${TIMEOUT}"
  fi

  # Get the compute zone
  zone=${ZONE:-"$(gcloud info --format='value(config.properties.compute.zone)')"}
  if [[ ${zone} == "" ]]; then
    echo "Could not find gcloud compute/zone when running: \`gcloud info --format='value(config.properties.compute.zone)'\`"
    exit 1
  fi

  # Get the compute project
  project=$(gcloud info --format='value(config.project)')
  if [[ ${project} == "" ]]; then
    echo "Could not find gcloud project when running: \`gcloud info --format='value(config.project)'\`"
    exit 1
  fi

  # Check if any of the images specified already have running instances.  If so reuse those instances
  # by moving the IMAGE to a HOST
  if [[ ${images} != "" ]]; then
  IFS=',' read -ra IM <<< "${images}"
       images=""
       for i in "${IM[@]}"; do
         if gcloud compute instances list --project="${project}" --filter="name:'${instance_prefix}-${i}' AND zone:'${zone}'" | grep "${i}"; then
           if [[ "${hosts}" != "" ]]; then
             hosts="${hosts},"
           fi
           echo "Reusing host ${instance_prefix}-${i}"
           hosts="${hosts}${instance_prefix}-${i}"
         else
           if [[ "${images}" != "" ]]; then
             images="${images},"
           fi
           images="${images}${i}"
         fi
       done
  fi

  # Use cluster.local as default dns-domain
  test_args='--dns-domain="'${KUBE_DNS_DOMAIN:-cluster.local}'" '${test_args}
  test_args='--kubelet-flags="--cluster-domain='${KUBE_DNS_DOMAIN:-cluster.local}'" '${test_args}

  # Output the configuration we will try to run
  echo "Running tests remotely using"
  echo "Project: ${project}"
  echo "Image Project: ${image_project}"
  echo "Compute/Zone: ${zone}"
  echo "Images: ${images}"
  echo "Hosts: ${hosts}"
  echo "Ginkgo Flags: ${ginkgoflags}"
  echo "Instance Metadata: ${metadata}"
  echo "Image Config File: ${image_config_file}"
  # Invoke the runner
  go run test/e2e_node/runner/remote/run_remote.go  --logtostderr --vmodule=*=4 --ssh-env="gce" \
    --zone="${zone}" --project="${project}" --gubernator="${gubernator}" \
    --hosts="${hosts}" --images="${images}" --cleanup="${cleanup}" \
    --results-dir="${artifacts}" --ginkgo-flags="${ginkgoflags}" \
    --image-project="${image_project}" --instance-name-prefix="${instance_prefix}" \
    --delete-instances="${delete_instances}" --test_args="${test_args}" --instance-metadata="${metadata}" \
    --image-config-file="${image_config_file}" --system-spec-name="${system_spec_name}" \
    --runtime-config="${runtime_config}" --preemptible-instances="${preemptible_instances}" \
    --ssh-user="${ssh_user}" --ssh-key="${ssh_key}" \
    --extra-envs="${extra_envs}" --test-suite="${test_suite}" \
    "${timeout_arg}" \
    2>&1 | tee -i "${artifacts}/build-log.txt"
  exit $?

else
  # Refresh sudo credentials if needed
  if ping -c 1 -q metadata.google.internal &> /dev/null; then
    echo 'Running on GCE, not asking for sudo credentials'
  elif sudo --non-interactive "$(which bash)" -c true 2> /dev/null; then
    # if we can run bash without a password, it's a pretty safe bet that either
    # we can run any command without a password, or that sudo credentials
    # are already cached - and they've just been re-cached
    echo 'No need to refresh sudo credentials'
  else
    echo 'Updating sudo credentials'
    sudo -v || exit 1
  fi

  # Do not use any network plugin by default. User could override the flags with
  # test_args.
  test_args='--kubelet-flags="--network-plugin= --cni-bin-dir=" '${test_args}

  # Runtime flags
  test_args='--kubelet-flags="--container-runtime='${runtime}'" '${test_args}

  # Use cluster.local as default dns-domain
  test_args='--dns-domain="'${KUBE_DNS_DOMAIN:-cluster.local}'" '${test_args}
  test_args='--kubelet-flags="--cluster-domain='${KUBE_DNS_DOMAIN:-cluster.local}'" '${test_args}
  # Test using the host the script was run on
  # Provided for backwards compatibility
  go run test/e2e_node/runner/local/run_local.go \
    --system-spec-name="${system_spec_name}" --extra-envs="${extra_envs}" \
    --ginkgo-flags="${ginkgoflags}" --test-flags="--container-runtime=${runtime} \
    --alsologtostderr --v 4 --report-dir=${artifacts} --node-name $(hostname) \
    ${test_args}" --runtime-config="${runtime_config}" \
    --build-dependencies=true 2>&1 | tee -i "${artifacts}/build-log.txt"
  exit $?
fi
