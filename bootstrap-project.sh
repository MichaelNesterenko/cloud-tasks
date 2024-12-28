#!/usr/bin/env bash

set -eEuo pipefail
shopt -s inherit_errexit

cfg="$1"

set -a; source "$cfg"; set +a

if ! gcloud --project "$TF_VAR_gcp_project_id" storage buckets describe "gs://$TF_VAR_app_state_bucket_name" &> /dev/null; then
    gcloud --project "$TF_VAR_gcp_project_id" storage buckets create "gs://${TF_VAR_app_state_bucket_name}" --public-access-prevention
else
    echo "bucket $TF_VAR_app_state_bucket_name already present"
fi

for api in $TF_VAR_gcp_project_api; do
    gcloud --project "$TF_VAR_gcp_project_id" services enable "$api"
done