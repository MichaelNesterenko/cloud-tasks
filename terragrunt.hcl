locals {
  gcp_project_id = get_env("TF_VAR_gcp_project_id")
  gcp_project_region = get_env("TF_VAR_gcp_project_region")
  gcp_project_zone = get_env("TF_VAR_gcp_project_zone")
  state_bucket_name = get_env("TF_VAR_app_state_bucket_name")
  state_bucket_folder = get_env("TF_VAR_app_state_bucket_folder")
}

generate "tg-injections" {
  path = "terragrunt.tf"
  if_exists = "overwrite_terragrunt"
  contents = <<EOF
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.14.0"
    }
    helm = {
      source = "hashicorp/helm"
      version = "~> 2.17.0"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "~> 2.35.1"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.2.3"
    }
  }
  backend "gcs" {
    bucket = "${local.state_bucket_name}"
    prefix = "${local.state_bucket_folder}"
  }
}
provider "google" {
  project = "${local.gcp_project_id}"
  region = "${local.gcp_project_region}"
  zone = "${local.gcp_project_zone}"
}
EOF
}
