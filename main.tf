# VPC
resource "google_compute_network" "vpc_network" {
  name                    = "app-network"
  auto_create_subnetworks = false
}
resource "google_compute_subnetwork" "vpc_subnetwork" {
  name            = "${google_compute_network.vpc_network.name}-us-central1"
  ip_cidr_range   = "10.1.0.0/24"
  network         = google_compute_network.vpc_network.id
  secondary_ip_range {
    range_name    = local.pod_ip_range_name
    ip_cidr_range = "10.2.0.0/19"
  }
  secondary_ip_range {
    range_name    = local.service_ip_range_name
    ip_cidr_range = "10.3.0.0/19"
  }
  private_ip_google_access = true
}
resource "google_compute_subnetwork" "gke_control_plane_subnetwork" {
    name            = "${google_compute_network.vpc_network.name}-gke-control-plane"
    ip_cidr_range   = "172.16.0.0/28"
    network         = google_compute_network.vpc_network.id
}
resource "google_compute_global_address" "private_service_addresses" {
    name          = "${google_compute_network.vpc_network.name}-private-services"
    address       = "10.4.0.0"
    prefix_length = 20
    address_type  = "INTERNAL"
    network       = google_compute_network.vpc_network.id
    purpose       = "VPC_PEERING"
}
resource "google_service_networking_connection" "private_service_connection" {
    network = google_compute_network.vpc_network.id
    service = "servicenetworking.googleapis.com"
    reserved_peering_ranges = [ google_compute_global_address.private_service_addresses.name ]
}
resource "google_compute_router" "router" {
    name    = "${google_compute_network.vpc_network.name}-router"
    network = google_compute_network.vpc_network.id
}
resource "google_compute_router_nat" "nat" {
    name                               = "nat-gateway"
    router                             = google_compute_router.router.name
    nat_ip_allocate_option             = "AUTO_ONLY"
    source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# GKE
resource "google_artifact_registry_repository" "gke_repository" {
    repository_id = "app-gke-repo"
    format = "DOCKER"
}
resource "google_service_account" "kubernetes_sa" {
    account_id = "app-kubernetes"
}
resource "google_project_iam_member" "kubernetes_iam" {
    project = var.gcp_project_id
    for_each = toset([
        "roles/artifactregistry.reader",
        "roles/logging.logWriter",
        "roles/monitoring.metricWriter",
        "roles/monitoring.viewer",
        "roles/stackdriver.resourceMetadata.writer",
        "roles/storage.objectViewer"
    ])
    role = each.key
    member = google_service_account.kubernetes_sa.member
}
resource "google_container_cluster" "cluster" {
    name = "app-cluster"
    deletion_protection = false

    network = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.vpc_subnetwork.id
    ip_allocation_policy {
        cluster_secondary_range_name = local.pod_ip_range_name
        services_secondary_range_name = local.service_ip_range_name
    }
    private_cluster_config {
        enable_private_nodes = true
        private_endpoint_subnetwork = google_compute_subnetwork.gke_control_plane_subnetwork.id
    }
    # master_authorized_networks_config { TODO until issue with private builder pool is resolved
    #     cidr_blocks {
    #         cidr_block = var.gke_external_access_cidr
    #     }
    # }

    remove_default_node_pool = true
    initial_node_count       = 1
    node_config {
        disk_size_gb = 30
    }

    workload_identity_config {
        workload_pool = "${data.google_project.project.project_id}.svc.id.goog"
    }
}
resource "google_container_node_pool" "cluster_nodes" {
    name = "${google_container_cluster.cluster.name}-nodes"
    cluster = google_container_cluster.cluster.name
    initial_node_count = 1
    node_locations = [
        "us-central1-a",
        "us-central1-b"
    ]
    node_config {
        machine_type = "n1-standard-1"
        service_account = google_service_account.kubernetes_sa.email
        disk_size_gb = 30

        workload_metadata_config {
            mode = "GKE_METADATA"
        }
    }
}

# DATABASE
resource "google_sql_database_instance" "mysql_database_instance" {
    depends_on = [google_service_networking_connection.private_service_connection]
    name = "app-database"
    deletion_protection = false
    database_version = "MYSQL_8_0"
    settings {
        edition = "ENTERPRISE"
        availability_type = "REGIONAL"
        tier = "db-n1-standard-1"

        disk_size = 10
        disk_type = "PD_SSD"
        disk_autoresize = true

        location_preference {
            zone = "us-central1-a"
            secondary_zone = "us-central1-b"
        }
        database_flags {
            name  = "cloudsql_iam_authentication"
            value = "on"
        }
        ip_configuration {
            ipv4_enabled = true
            private_network = google_compute_network.vpc_network.id
            allocated_ip_range = google_compute_global_address.private_service_addresses.name
        }
        backup_configuration {
            enabled = true
            binary_log_enabled = true
            location = "US"
            transaction_log_retention_days = 7
            backup_retention_settings {
                retained_backups = 30
                retention_unit = "COUNT"
            }
        }
        maintenance_window {
            day = 7
            hour = 0
        }
    }
}
resource "google_sql_database" "app_database" {
    name = "app"
    instance = google_sql_database_instance.mysql_database_instance.name
    charset = "utf8mb4"
    collation = "utf8mb4_general_ci"
}
resource "google_sql_user" "app_database_user" {
    name = local.app_database_username
    instance = google_sql_database_instance.mysql_database_instance.name
    type = "CLOUD_IAM_SERVICE_ACCOUNT"
}
resource "google_sql_user" "migration_database_user" {
    name = local.migration_database_username
    instance = google_sql_database_instance.mysql_database_instance.name
    password = local.migration_database_password
}
resource "google_secret_manager_secret" "app_migration_db_user_secret" {
    for_each = toset([
        "app-migration-db-username",
        "app-migration-db-password",
    ])
    secret_id = each.key
    replication {
        auto {}
    }
}
resource "google_secret_manager_secret_version" "app_migration_db_user_secret_value" {
    for_each = tomap({
        app-db-migration-username: {
            id: google_secret_manager_secret.app_migration_db_user_secret["app-migration-db-username"].id,
            value: local.migration_database_username
        },
        app-db-migration-password: {
            id: google_secret_manager_secret.app_migration_db_user_secret["app-migration-db-password"].id,
            value: local.migration_database_password,
        }
    })
    secret = each.value.id
    secret_data = each.value.value
}

# INGRESS
resource "helm_release" "nginx_ingress" {
    name = "nginx-ingress-controller"

    repository = "oci://registry-1.docker.io/bitnamicharts"
    chart      = "nginx-ingress-controller"
}


# CLOUD BUILD
resource "google_storage_bucket" "cloud_build_storage" {
    name = "${var.gcp_project_id}-app-cloudbuild"
    location = var.gcp_project_region
    force_destroy = true
    uniform_bucket_level_access = true
    public_access_prevention = "enforced"

    lifecycle_rule {
        condition {
            age = 3
        }
        action {
            type = "Delete"
        }
    }
}
resource "google_service_account" "app_build_sa" {
    account_id = "app-build"
}
resource "google_project_iam_member" "app_build_sa_iam" {
    project = var.gcp_project_id
    for_each = toset([
        "roles/storage.admin",
        "roles/iam.serviceAccountUser",
        "roles/logging.logWriter",
        "roles/artifactregistry.writer",
        "roles/cloudsql.client",
        "roles/secretmanager.secretAccessor",
        "roles/container.developer"
    ])
    role = each.key
    member = google_service_account.app_build_sa.member
}
resource "google_secret_manager_secret" "github_access_token" {
  secret_id = "github-access-toke"
  replication {
    auto {}
  }
}
resource "google_secret_manager_secret_version" "github_access_token_value" {
    secret = google_secret_manager_secret.github_access_token.id
    secret_data = var.github_token
}
resource "google_project_iam_member" "service_github_secret_access" {
    project = var.gcp_project_id
    role = "roles/secretmanager.secretAccessor"
    member = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
}
resource "google_cloudbuildv2_connection" "github_repo_connection" {
    depends_on = [ google_project_iam_member.service_github_secret_access ]
    location = var.gcp_project_region
    name = "github-connection"
    github_config {
        app_installation_id = 59015815
        authorizer_credential {
            oauth_token_secret_version = google_secret_manager_secret_version.github_access_token_value.id
        }
    }
}
resource "google_cloudbuildv2_repository" "app_repository" {
    name = "cloud-tasks"
    parent_connection = google_cloudbuildv2_connection.github_repo_connection.id
    remote_uri = "https://github.com/MichaelNesterenko/cloud-tasks.git"
}
resource "google_cloudbuild_trigger" "app_repository_trigger" {
    location = var.gcp_project_region
    service_account = google_service_account.app_build_sa.id
    repository_event_config {
        repository = google_cloudbuildv2_repository.app_repository.id
        push {
            branch = "cloud-dev-app"
        }
    }
    filename = "cloudbuild.yaml"
}
resource "google_cloudbuild_worker_pool" "app_build_pool" {
    name = "app-build-pool"
    location = var.gcp_project_region
    worker_config {
        disk_size_gb = 100
        machine_type = "e2-standard-4"
        no_external_ip = false
    }
    network_config {
        peered_network = google_compute_network.vpc_network.id
    }
}

# APP
resource "google_service_account" "app_sa" {
    account_id = "app-sa"
}
resource "google_project_iam_member" "app_sa_iam" {
    project = var.gcp_project_id
    for_each = toset([
        "roles/cloudsql.admin"
    ])
    role = each.key
    member = google_service_account.app_sa.member
}
resource "kubernetes_service_account" "app_ksa" {
    metadata {
        name = "app-ksa"
        annotations = {
            "iam.gke.io/gcp-service-account": google_service_account.app_sa.email
        }
    }
}
resource "google_service_account_iam_binding" "app_gsa_iam" {
    service_account_id = google_service_account.app_sa.name
    role = "roles/iam.workloadIdentityUser"
    members = [
        "serviceAccount:${var.gcp_project_id}.svc.id.goog[${kubernetes_service_account.app_ksa.metadata[0].namespace}/${kubernetes_service_account.app_ksa.metadata[0].name}]"
    ]
}
resource "kubernetes_config_map" "app_db_gke_cofig" {
    metadata {
        name = "app-db-config"
    }
    data = {
        db_user = local.app_database_username
        db_name = google_sql_database.app_database.name
        db_host = google_sql_database_instance.mysql_database_instance.connection_name
    }
}

provider "helm" {
    kubernetes {
        host = "https://${google_container_cluster.cluster.endpoint}"
        token = data.google_client_config.provider.access_token
        cluster_ca_certificate = base64decode(google_container_cluster.cluster.master_auth[0].cluster_ca_certificate)
        exec {
            api_version = "client.authentication.k8s.io/v1beta1"
            command     = "gke-gcloud-auth-plugin"
        }
    }
}
provider "kubernetes" {
    host = "https://${google_container_cluster.cluster.endpoint}"
    token = data.google_client_config.provider.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.cluster.master_auth[0].cluster_ca_certificate)
    exec {
        api_version = "client.authentication.k8s.io/v1beta1"
        command     = "gke-gcloud-auth-plugin"
    }
}

data "google_project" "project" {}
data "google_client_config" "provider" {}

locals {
    pod_ip_range_name = "pods"
    service_ip_range_name = "services"

    app_database_username = google_service_account.app_sa.email
    migration_database_username = "app-migration"
    migration_database_password = "s3cr3t"
}

variable "gke_external_access_cidr" {
    type = string
}
variable "gcp_project_id" {
    type = string
}
variable "gcp_project_region" {
    type = string
}
variable "github_token" {
    type = string
}