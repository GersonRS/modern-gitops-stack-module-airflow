resource "null_resource" "dependencies" {
  triggers = var.dependency_ids
}

resource "random_password" "airflow_webserver_secret_key" {
  length  = 16
  special = false
  depends_on = [
    resource.null_resource.dependencies,
  ]
}
resource "kubernetes_namespace" "airflow_namespace" {
  metadata {
    annotations = {
      name = "airflow"
    }
    name = "airflow"
  }
  depends_on = [
    resource.null_resource.dependencies,
  ]
}

resource "kubernetes_secret" "airflow_ssh_secret" {
  metadata {
    name      = "airflow-ssh-secret"
    namespace = "airflow"
  }

  data = {
    gitSshKey = file("${var.home_ssh}")
  }

  depends_on = [kubernetes_namespace.airflow_namespace]
}

resource "argocd_project" "this" {
  count = var.argocd_project == null ? 1 : 0

  metadata {
    name      = var.destination_cluster != "in-cluster" ? "airflow-${var.destination_cluster}" : "airflow"
    namespace = "argocd"
    annotations = {
      "modern-gitops-stack.io/argocd_namespace" = "argocd"
    }
  }

  spec {
    description  = "Airflow application project for cluster ${var.destination_cluster}"
    source_repos = ["https://github.com/GersonRS/modern-gitops-stack-module-airflow.git"]

    destination {
      name      = var.destination_cluster
      namespace = "airflow"
    }

    orphaned_resources {
      warn = true
    }

    cluster_resource_whitelist {
      group = "*"
      kind  = "*"
    }
  }
}

data "utils_deep_merge_yaml" "values" {
  input = [for i in concat(local.helm_values, var.helm_values) : yamlencode(i)]
}

resource "argocd_application" "this" {
  metadata {
    name      = var.destination_cluster != "in-cluster" ? "airflow-${var.destination_cluster}" : "airflow"
    namespace = "argocd"
    labels = merge({
      "application" = "airflow"
      "cluster"     = var.destination_cluster
    }, var.argocd_labels)
  }

  timeouts {
    create = "15m"
    delete = "15m"
  }

  wait = var.app_autosync == { "allow_empty" = tobool(null), "prune" = tobool(null), "self_heal" = tobool(null) } ? false : true

  spec {
    project = var.argocd_project == null ? argocd_project.this[0].metadata.0.name : var.argocd_project

    source {
      repo_url        = "https://github.com/GersonRS/modern-gitops-stack-module-airflow.git"
      path            = "charts/airflow"
      target_revision = var.target_revision
      helm {
        values = data.utils_deep_merge_yaml.values.output
      }
    }

    destination {
      name      = var.destination_cluster
      namespace = "airflow"
    }

    sync_policy {
      dynamic "automated" {
        for_each = toset(var.app_autosync == { "allow_empty" = tobool(null), "prune" = tobool(null), "self_heal" = tobool(null) } ? [] : [var.app_autosync])
        content {
          prune       = automated.value.prune
          self_heal   = automated.value.self_heal
          allow_empty = automated.value.allow_empty
        }
      }

      retry {
        backoff {
          duration     = "20s"
          max_duration = "2m"
          factor       = "2"
        }
        limit = "5"
      }

      sync_options = [
        "CreateNamespace=true"
      ]


    }
  }

  depends_on = [
    resource.null_resource.dependencies,
    kubernetes_secret.airflow_ssh_secret
  ]
}

resource "null_resource" "this" {
  depends_on = [
    resource.argocd_application.this,
  ]
}
