# configure providers
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 2.96"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">=2.18.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.8.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.13"
    }
  }
}

locals {
  subscription_id = ""
  tenant_id       = ""
  rg_name         = ""
  location        = "westus2"
  redis_password  = ""
  use_cluster     = true
}

provider "azurerm" {
  features {}
  subscription_id = local.subscription_id
  tenant_id       = local.tenant_id
}

resource "azurerm_kubernetes_cluster" "demo" {
  name                = "demoaks"
  location            = local.location
  resource_group_name = local.rg_name
  dns_prefix          = "demoaksredis"
  kubernetes_version  = "1.21.9"

  default_node_pool {
    name                = "cpupool1"
    enable_auto_scaling = true
    vm_size             = "Standard_D2s_v3"
    min_count           = local.use_cluster ? 6 : 1 # minimum 6 nodes for 3 masters and 3 replicas if using in cluster mode
    max_count           = 10
  }

  identity {
    type = "SystemAssigned"
  }
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.demo.kube_config.0.host
  username               = azurerm_kubernetes_cluster.demo.kube_config.0.username
  password               = azurerm_kubernetes_cluster.demo.kube_config.0.password
  client_certificate     = base64decode(azurerm_kubernetes_cluster.demo.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.demo.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.demo.kube_config.0.cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.demo.kube_config.0.host
    username               = azurerm_kubernetes_cluster.demo.kube_config.0.username
    password               = azurerm_kubernetes_cluster.demo.kube_config.0.password
    client_certificate     = base64decode(azurerm_kubernetes_cluster.demo.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.demo.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.demo.kube_config.0.cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = azurerm_kubernetes_cluster.demo.kube_config.0.host
  username               = azurerm_kubernetes_cluster.demo.kube_config.0.username
  password               = azurerm_kubernetes_cluster.demo.kube_config.0.password
  client_certificate     = base64decode(azurerm_kubernetes_cluster.demo.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.demo.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.demo.kube_config.0.cluster_ca_certificate)
  load_config_file       = false
}

# create redis-operator namespace
resource "kubernetes_namespace" "redis_operator_ns" {
  metadata {
    name = "redis-operator"
    labels = {
      "control-plane" = "redis-operator"
    }
  }
}

# create ot-operators namespace
resource "kubernetes_namespace" "ot_operator_ns" {
  metadata {
    name = "ot-operators"
  }
}

resource "kubectl_manifest" "redis_step1" {
  wait             = true
  wait_for_rollout = true
  yaml_body        = file("${path.module}/yaml/redis.redis.opstreelabs.in_redis.yaml")
  timeouts {
    create = "2m"
  }
  depends_on = [kubernetes_namespace.redis_operator_ns]
}

resource "kubectl_manifest" "redis_step2" {
  wait             = true
  wait_for_rollout = true
  yaml_body        = file("${path.module}/yaml/redis.redis.opstreelabs.in_redisclusters.yaml")
  timeouts {
    create = "2m"
  }
  depends_on = [kubectl_manifest.redis_step1]
}

resource "kubectl_manifest" "redis_step3" {
  wait             = true
  wait_for_rollout = true
  yaml_body        = file("${path.module}/yaml/serviceaccount.yaml")
  timeouts {
    create = "2m"
  }
  depends_on = [kubectl_manifest.redis_step2]
}

resource "kubectl_manifest" "redis_step4" {
  wait             = true
  wait_for_rollout = true
  yaml_body        = file("${path.module}/yaml/role.yaml")
  timeouts {
    create = "2m"
  }
  depends_on = [kubectl_manifest.redis_step3]
}

resource "kubectl_manifest" "redis_step5" {
  wait             = true
  wait_for_rollout = true
  yaml_body        = file("${path.module}/yaml/role_binding.yaml")
  timeouts {
    create = "2m"
  }
  depends_on = [kubectl_manifest.redis_step4]
}

resource "kubectl_manifest" "redis_step6" {
  wait             = true
  wait_for_rollout = true
  yaml_body        = file("${path.module}/yaml/manager.yaml")
  timeouts {
    create = "2m"
  }
  depends_on = [kubectl_manifest.redis_step5]
}

# create password for redis
resource "kubernetes_secret" "redis_secret" {
  metadata {
    name      = "redis-secret"
    namespace = "ot-operators"
  }

  data = {
    password = local.redis_password
  }

  type       = "generic"
  depends_on = [kubernetes_namespace.ot_operator_ns, kubectl_manifest.redis_step6]
}

resource "kubectl_manifest" "redis_standalone" {
  count            = local.use_cluster ? 0 : 1
  wait             = true
  wait_for_rollout = true
  yaml_body = templatefile("${path.module}/yaml/redis_standalone.yaml",
    {
      CPU_REQUEST : "1000m"
      MEMORY_REQUEST : "2Gi"
    }
  )
  timeouts {
    create = "10m"
  }
  depends_on = [kubernetes_secret.redis_secret]
}

resource "kubectl_manifest" "redis_cluster" {
  count            = local.use_cluster ? 1 : 0
  wait             = true
  wait_for_rollout = true
  yaml_body = templatefile("${path.module}/yaml/redis_cluster.yaml",
    {
      CPU_REQUEST : "1000m"
      MEMORY_REQUEST : "2Gi"
    }
  )
  timeouts {
    create = "10m"
  }
  depends_on = [kubernetes_secret.redis_secret]
}

output "redis_info" {
  value = {
    redis_address  = local.use_cluster ? "redis-cluster-leader.ot-operators" : "redis-standalone.ot-operators"
    redis_port     = 6379
    redis_password = local.redis_password
    redis_use_ssl  = "false"
  }
  depends_on = [kubectl_manifest.redis_standalone, kubectl_manifest.redis_cluster]
}
