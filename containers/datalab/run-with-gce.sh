#!/bin/bash -e

# Copyright 2016 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

USAGE="USAGE: ${0} [<PROJECT> <ZONE> [<DOCKER_BRIDGE_IP>]]

Where <PROJECT> is the ID of the Google Cloud Platform project that will host
the kernel gateway, <ZONE> is the Google Compute Engine zone where the kernel
gateway will run, and <DOCKER_BRIDGE_IP> is the IP address of the 'docker0'
network bridge.

The <PROJECT> and <ZONE> arguments can be omitted if you set the default
project and zone using the gcloud tool:

    gcloud config set project <PROJECT>
    gcloud config set compute/zone <ZONE>

If the <DOCKER_BRIDGE_IP> argument is omitted, then the tool will attempt
to look it up using the 'ifconfig' command.
"

ERR_USAGE=1
ERR_LOGIN=2
ERR_DEPLOY=3

DOCS="This script runs Datalab connected to a kernel gateway running in a GCE VM.

The script will first look to see if there is an existing kernel gateway VM,
and if it cannot find one then it will create one using the
'../gateway/deploy.sh' script.

The connection between the locally-running Datalab instance and the kernel
gateway will be tunnelled through an SSH session to the VM hosting the kernel
gateway. When this script is terminated, it will also kill that SSH session.

If a new GCE VM is created, then it will remain running until deleted, so
please remember to delete that VM if you no longer need it to avoid incurring
unnecessary costs.
"

PROJECT=${1:-`gcloud config list 2> /dev/null | grep 'project = ' | cut -d ' ' -f 3`}
ZONE=${2:-`gcloud config list 2> /dev/null | grep 'zone = ' | cut -d ' ' -f 3`}
DOCKER_IP=${3:-`ifconfig docker0 | grep inet\ addr: | cut -d ':' -f 2 | cut -d ' ' -f 1`}

if [[ -z "${PROJECT}" || -z "${ZONE}" || -z "${DOCKER_IP}" ]]; then
  echo "${USAGE}"
  exit ${ERR_USAGE}
fi

echo "${DOCS}"

# We want to run the kernel gateway in a VM. However, we also want to make sure
# there is a 1:1 correspondence between end user and kernel gateway, so we need
# to create a separate VM for each user.
#
# To do this, we will name the VM with a prefix tied to the user. Since
# usernames can include arbitrary characters, we sanitize the username by first
# hashing it. We use the openssl implementation of sha1 for this purpose,
# solely for the fact that it should be nearly ubiquitous.
#
# NOTE: THIS IS NOT A SECURITY SANDBOX. When running in a GCE VM, Datalab is in
# an inherently shared environment. This separation is merely to prevent
# accidental conflicts between users, not to provide any sort of privacy or
# authentication.
USER_EMAIL=`gcloud info --format="value(config.account)"`
if [[ -z "${USER_EMAIL}" ]]; then
  echo "You must log in via the gcloud tool"
  echo "    gcloud auth login"
  exit ${ERR_LOGIN}
fi

echo "Looking up gateway VM for ${USER_EMAIL}..."

USER_HASH=`echo "${USER_EMAIL}" | openssl sha1 -r | cut -d ' ' -f 1`
INSTANCE_PREFIX="datalab-gateway-${USER_HASH:0:12}"

INSTANCE=`gcloud compute instances list --project "${PROJECT}" --zone "${ZONE}" --regex "${INSTANCE_PREFIX}-[0-9]*" --limit 1 --format "value(name)"`
if [[ -z "${INSTANCE}" ]]; then
  echo "Could not find an existing gateway VM for '${USER_EMAIL}'. Will create one..."
  INSTANCE="${INSTANCE_PREFIX}-${RANDOM}"
  pushd ./
  cd ../gateway
  ./deploy.sh "${PROJECT}" "${ZONE}" "${INSTANCE}" || exit ${ERR_DEPLOY}
  popd
fi

echo "Will connect to the kernel gateway running on ${INSTANCE}"

# We want to run the SSH command in the background but save the PID
# so we can kill it on exit. However, if we ran the command through
# gcloud, then the PID we would get would be that of the gcloud
# command, which exits after starting the SSH command.
#
# To get around this, we only use gcloud to print the SSH command
# (via the --dry-run flag), and then run that SSH command directly.
#
# Unfortunately, the --dry-run flag also prevents the SSH keys from
# being cascaded to the VM, so we also have to run a no-op SSH
# command first to perform the SSH key setup. However, that has the
# added benefit of ensuring that the VM is SSH-able before we try
# to connect to it
gcloud compute ssh --project "${PROJECT}" \
  --zone "${ZONE}" \
  "${INSTANCE}" \
  "true"
SSH_CMD=`gcloud compute ssh --dry-run --project "${PROJECT}" --zone "${ZONE}" --ssh-flag="-NL" --ssh-flag="${DOCKER_IP}:8082:localhost:8080" "${INSTANCE}"`
${SSH_CMD} &
SSH_PID="$!"

# Install a trap that will kill the background SSH process on exit.
trap "kill -9 ${SSH_PID}" EXIT

echo "Started SSH tunnel with PID ${SSH_PID}"

EXPERIMENTAL_KERNEL_GATEWAY_URL="http://${DOCKER_IP}:8082" ./run.sh

# The following command should be redundant given the trap above, but better safe than sorry.
kill -9 "${SSH_PID}"
