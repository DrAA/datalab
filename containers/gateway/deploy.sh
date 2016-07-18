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

USAGE="USAGE: ${0} [<PROJECT> <ZONE> [<INSTANCE>]]

If the project and zone are not provided, then they must be set using the gcloud tool:

    gcloud config set project <PROJECT>
    gcloud config set compute/zone <ZONE>
"

ERR_USAGE=1
ERR_CANCELLED=2
ERR_DOCKER_BUILD=3
ERR_DOCKER_PUSH=4
ERR_NETWORK_CREATE=5
ERR_FIREWALL_RULE=6
ERR_INSTANCE_CREATE=7

DOCS="This script deploys the Datalab kernel gateway to a GCE VM.

This will:

1. Build the gateway image and push it to GCR.
2. Ensure that the project contains a network named
   'datalab-kernels' with inbound SSH connections allowed
3. Crate a new VM in the default zone connected to the
   'datalab-kernels' network.
4. Run the gateway image in that VM

The resulting VM can be used by running the 'run-with-gce.sh'
script in the 'containers/datalab' directory to set up an
instance of Datalab connected to that VM via an SSH tunnel.
"

PROJECT=${1:-`gcloud config list 2> /dev/null | grep 'project = ' | cut -d ' ' -f 3`}
ZONE=${2:-`gcloud config list 2> /dev/null | grep 'zone = ' | cut -d ' ' -f 3`}
INSTANCE=${3:-"datalab-kernel-gateway"}

if [[ -z "${PROJECT}" || -z "${ZONE}" || -z "${INSTANCE}" ]]; then
  echo "${USAGE}"
  exit ${ERR_USAGE}
fi

echo "${DOCS}"

echo "Will deploy a GCE VM named '${INSTANCE}' to the project '${PROJECT}' in zone '${ZONE}'"
read -p "Proceed? [y/N] " PROCEED

if [[ "${PROCEED}" != "y" ]]; then
  echo "Deploy cancelled"
  exit ${ERR_CANCELLED}
fi

# TODO(ojarjur): Add support for pulling a pre-built version of the
# datalab-gateway image, rather than building from source.
./build.sh || exit ${ERR_DOCKER_BUILD}
IMAGE="gcr.io/${PROJECT}/datalab-gateway"
docker tag -f datalab-gateway "${IMAGE}"
gcloud docker push "${IMAGE}" || exit ${ERR_DOCKER_PUSH}

NETWORK="datalab-kernels"
if [[ -z `gcloud --project "${PROJECT}" compute networks list | grep ${NETWORK}` ]]; then
  echo "Creating the compute network '${NETWORK}'"
  gcloud compute networks create "${NETWORK}" --project "${PROJECT}" --description "Network for Datalab kernel gateway VMs" || exit ${ERR_NETWORK_CREATE}
  gcloud compute firewall-rules create allow-ssh --project "${PROJECT}" --allow tcp:22 --description 'Allow SSH access' --network "${NETWORK}" || exit ${ERR_FIREWALL_RULE}
fi

CONFIG="apiVersion: v1
kind: Pod
metadata:
  name: datalab-kernel-gateway
spec:
  containers:
    - name: datalab-kernel-gateway
      image: ${IMAGE}
      command: ['/datalab/run.sh']
      imagePullPolicy: IfNotPresent
      ports:
        - containerPort: 8080
          hostPort: 8080
      env:
        - name: DATALAB_ENV
          value: GCE
"

echo "Creating the compute VM ${INSTANCE} with config: ${CONFIG}"
gcloud compute instances create "${INSTANCE}" \
    --project "${PROJECT}" \
    --zone "${ZONE}" \
    --network "${NETWORK}" \
    --image-family "container-vm" \
    --image-project "google-containers" \
    --metadata "google-container-manifest=${CONFIG}" \
    --machine-type "n1-highmem-2" \
    --scopes "cloud-platform" || exit ${ERR_INSTANCE_CREATE}

echo "Finished creating the vm ${INSTANCE} running a Datalab kernel gateway

When you no longer need it, please remember to delete the instance to avoid incurring additional costs.

The command to delete this instance is:

    gcloud compute instances delete ${INSTANCE} --project ${PROJECT} --zone ${ZONE}
"
