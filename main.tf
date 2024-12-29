resource "google_compute_network" "vpc_network" {
  name                    = "network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "vpc_subnetwork" {
  name            = "us-central1-subnet"
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
    name            = "gke-control-plane-subnet"
    ip_cidr_range   = "172.16.0.0/28"
    network         = google_compute_network.vpc_network.id
}

resource "google_compute_global_address" "private_service_addresses" {
    name          = "private-services"
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
    name    = "network-router"
    network = google_compute_network.vpc_network.id
}

resource "google_compute_router_nat" "nat" {
    name                               = "nat-gateway"
    router                             = google_compute_router.router.name
    nat_ip_allocate_option             = "AUTO_ONLY"
    source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_service_account" "kubernetes_sa" {
    account_id = "kubernetes"
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

resource "google_service_account" "nextcloud_sa" {
    account_id = "nextcloud"
}
resource "google_project_iam_member" "nextcloud_sa_iam" {
    project = var.gcp_project_id
    for_each = toset([
        "roles/storage.objectAdmin"
    ])
    role = each.key
    member = google_service_account.nextcloud_sa.member
}

resource "google_container_cluster" "cluster" {
    name = "cluster"
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
    master_authorized_networks_config {
        cidr_blocks {
            cidr_block = var.gke_external_access_cidr
        }
    }

    remove_default_node_pool = true
    initial_node_count       = 1
    node_config {
        disk_size_gb = 30
    }
}
resource "google_container_node_pool" "cluster_nodes" {
    name = "cluster-nodes"
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
    }
}
resource "google_artifact_registry_repository" "gke_repository" {
    repository_id = "gke-repo"
    format = "DOCKER"
}

resource "google_sql_database_instance" "mysql_database_instance" {
    depends_on = [google_service_networking_connection.private_service_connection]
    name = "database"
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
        ip_configuration {
            ipv4_enabled = false
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
resource "google_sql_database" "nextcloud_database" {
    name = "nextcloud"
    instance = google_sql_database_instance.mysql_database_instance.name
    charset = "utf8mb4"
    collation = "utf8mb4_general_ci"
}
resource "google_sql_user" "nextcloud_database_user" {
    name = local.nextcloud_database_username
    instance = google_sql_database_instance.mysql_database_instance.name
    password = local.nextcloud_database_password
}

resource "google_redis_instance" "redis_instance" {
    depends_on = [google_service_networking_connection.private_service_connection]
    name = "redis"
    memory_size_gb = 1
    tier = "STANDARD_HA"
    redis_version = "REDIS_5_0"

    connect_mode = "PRIVATE_SERVICE_ACCESS"
    authorized_network = google_compute_network.vpc_network.id
}

resource "google_storage_bucket" "cloud-build-storage" {
    name = "${var.gcp_project_id}_cloudbuild"
    location = var.gcp_project_region
    force_destroy = true
    uniform_bucket_level_access = false
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

resource "google_storage_bucket" "nextcloud-external-data" {
    name = "${var.gcp_project_id}-nextcloud-external-data"
    location = var.gcp_project_region
    force_destroy = true
    uniform_bucket_level_access = false
    public_access_prevention = "enforced"
}
resource "google_storage_hmac_key" "nextcloud-external-data-key" {
    service_account_email = google_service_account.nextcloud_sa.email
}

resource "kubernetes_secret" "nextcloud_gke_secrets" {
    for_each = tomap({
        nextcloud-mysql = {
            secret_user = local.nextcloud_database_username
            secret_pass = local.nextcloud_database_password
        }
        nextcloud-admin = {
            secret_user = "admin"
            secret_pass = "admin123"
        }
    })
    metadata {
        name = each.key
    }
    data = {
        username = each.value.secret_user
        password = each.value.secret_pass
    }
    type = "kubernetes.io/basic-auth"
}

resource "null_resource" "nextcloud_build" {
  depends_on = [
    google_storage_bucket.cloud-build-storage,
    google_artifact_registry_repository.gke_repository
  ]
  triggers = {
    "t" = timestamp()
  }
  provisioner "local-exec" {
    command = "gcloud --project ${var.gcp_project_id} builds submit --tag ${local.nextcloud_image_name}:${local.nextcloud_image_tag}"
    working_dir = "${local.nextcloud_dir}/nextcloud-docker"
  }
}

resource "helm_release" "nginx_ingress" {
    name = "nginx-ingress-controller"

    repository = "oci://registry-1.docker.io/bitnamicharts"
    chart      = "nginx-ingress-controller"
}
resource "helm_release" "nexctcloud" {
    depends_on = [ null_resource.nextcloud_build ]
    name = "nextcloud"

    # some issues with https repositories
    # repository = "https://nextcloud.github.io/helm/"
    # chart      = "nextcloud"
    # version    = "2.8.1"
    chart = "https://github.com/nextcloud/helm/releases/download/nextcloud-2.8.1/nextcloud-2.8.1.tgz"

    values = [file("${local.nextcloud_dir}/values.example.yaml")]
    set {
        name = "image.repository"
        value = local.nextcloud_image_name
    }
    set {
        name = "image.tag"
        value = local.nextcloud_image_tag
    }
    set {
        name = "image.pullPolicy"
        value = "Always"
    }
    set {
        name = "nextcloud.configs.gcs\\.config\\.php"
        value = <<EOT
<?php
$CONFIG = array(
    'objectstore' => array(
        'class' => '\\OC\\Files\\ObjectStore\\S3'\,
        'arguments' => array(
            'bucket'         => '${google_storage_bucket.nextcloud-external-data.name}'\,
            'autocreate'     => false\,
            'key'            => '${google_storage_hmac_key.nextcloud-external-data-key.access_id}'\,
            'secret'         => '${google_storage_hmac_key.nextcloud-external-data-key.secret}'\,
            'hostname'       => 'storage.googleapis.com'\,
            'region'         => 'auto'\,
            'use_ssl'        => true\,
            'use_path_style' => false
        )
    )
);
EOT
    }
    set {
        name = "nextcloud.configs.memorystore\\.config\\.php"
        value = <<EOT
<?php
$CONFIG = array(
    'memcache.local' => '\\OC\\Memcache\\Redis'\,
    'redis' => array(
        'host' => '${google_redis_instance.redis_instance.host}'\,
        'port' => 6379
    )
);
EOT
    }
    set {
        name = "externalDatabase.host"
        value = google_sql_database_instance.mysql_database_instance.private_ip_address
    }
    set {
        name = "externalDatabase.database"
        value = google_sql_database.nextcloud_database.name
    }
    set {
        name = "livenessProbe.initialDelaySeconds"
        value = 60
    }
    set {
        name = "readinessProbe.initialDelaySeconds"
        value = 60
    }
    set {
        name = "readinessProbe.initialDelaySeconds"
        value = 60
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

    nextcloud_database_username = "nextcloud"
    nextcloud_database_password = "s3cr3t"

    nextcloud_dir = abspath("${path.module}/nextcloud/")

    nextcloud_image_name = "${google_artifact_registry_repository.gke_repository.location}-docker.pkg.dev/${var.gcp_project_id}/${google_artifact_registry_repository.gke_repository.name}/nextcloud"
    nextcloud_image_tag = "21.0.1-apache"
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