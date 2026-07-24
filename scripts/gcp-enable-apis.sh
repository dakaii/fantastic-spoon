#!/usr/bin/env bash
# gcp-enable-apis.sh — Enable all GCP APIs used by this platform
set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:?Set GCP_PROJECT}"

APIS=(
  compute.googleapis.com
  storage.googleapis.com
  dns.googleapis.com
  cloudfunctions.googleapis.com
  cloudscheduler.googleapis.com
  workflows.googleapis.com
  firestore.googleapis.com
  pubsub.googleapis.com
  iam.googleapis.com
  serviceusage.googleapis.com
  cloudresourcemanager.googleapis.com
  # Cloud Functions Gen2 (Phase 4 witness + Level C activate)
  run.googleapis.com
  cloudbuild.googleapis.com
  artifactregistry.googleapis.com
  eventarc.googleapis.com
  secretmanager.googleapis.com
)

echo "==> Enabling APIs on project ${GCP_PROJECT}"
gcloud services enable "${APIS[@]}" --project="$GCP_PROJECT"
echo "==> APIs enabled"
