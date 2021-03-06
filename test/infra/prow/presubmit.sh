#!/bin/bash
#
# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit  # Exit with error on non-zero exit codes
set -o pipefail # Check the exit code of *all* commands in a pipeline
set -o nounset  # Error if accessing an unbound variable
set -x          # Print each command as it is run

export CLUSTER_NAME=management-cluster
export PROJECT_ID=secretmanager-csi-build
export SECRET_STORE_VERSION=ad965e92d14a87ad88f7f61c764afaede1ff6107

# Populated by prow pod utilities
# https://github.com/kubernetes/test-infra/blob/master/prow/pod-utilities.md#pod-utilities
export GCP_PROVIDER_SHA=${GCP_PROVIDER_SHA:-$PULL_PULL_SHA}

# Use the SA token in environment variable to run gCloud commands if provided
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS+set}" ]; then
    gcloud auth activate-service-account --key-file ${GOOGLE_APPLICATION_CREDENTIALS}
fi

# Build the driver image
gcloud builds submit --config scripts/cloudbuild-dev.yaml --substitutions=TAG_NAME=${GCP_PROVIDER_SHA} --project $PROJECT_ID

# Build test images for E2E testing
gcloud builds submit --config test/e2e/cloudbuild.yaml --substitutions="_SECRET_STORE_VERSION=${SECRET_STORE_VERSION},_GCP_PROVIDER_SHA=${GCP_PROVIDER_SHA}" --project $PROJECT_ID test/e2e

export JOB_NAME="e2e-test-job-$(head /dev/urandom | base64 | tr -dc 'a-z' | head -c 8)"

# Start up E2E tests
gcloud container clusters get-credentials $CLUSTER_NAME --zone us-central1-c --project $PROJECT_ID
sed "s/\$GCP_PROVIDER_SHA/${GCP_PROVIDER_SHA}/g;s/\$PROJECT_ID/${PROJECT_ID}/g;s/\$JOB_NAME/${JOB_NAME}/g" \
    test/e2e/e2e-test-job.yaml.tmpl | kubectl apply -f -

# Wait until job start, then subscribe to job logs
kubectl wait pod --for=condition=ready -l job-name="${JOB_NAME}" -n e2e-test
kubectl logs -n e2e-test -l job-name="${JOB_NAME}" -f | sed "s/^/TEST: /" &

while true; do
    if kubectl wait --for=condition=complete "job/${JOB_NAME}" -n e2e-test --timeout 0 > /dev/null 2>&1; then
        echo "Job completed"
        kubectl delete job "${JOB_NAME}" -n e2e-test
        exit 0
    fi

    if kubectl wait --for=condition=failed "job/${JOB_NAME}" -n e2e-test --timeout 0 > /dev/null 2>&1; then
        echo "Job failed"
        kubectl delete job "${JOB_NAME}" -n e2e-test
        exit 1
    fi

    sleep 30
done
