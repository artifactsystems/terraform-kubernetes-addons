locals {

  karpenter = merge(
    local.helm_defaults,
    {
      name                            = local.helm_dependencies[index(local.helm_dependencies.*.name, "karpenter")].name
      chart                           = local.helm_dependencies[index(local.helm_dependencies.*.name, "karpenter")].name
      repository                      = local.helm_dependencies[index(local.helm_dependencies.*.name, "karpenter")].repository
      chart_version                   = local.helm_dependencies[index(local.helm_dependencies.*.name, "karpenter")].version
      namespace                       = "karpenter"
      enabled                         = false
      create_ns                       = true
      default_network_policy          = true
      irsa_oidc_provider_arn          = var.eks["oidc_provider_arn"]
      irsa_namespace_service_accounts = ["karpenter:karpenter"]
      allowed_cidrs                   = ["0.0.0.0/0"]
      iam_role_name                   = ""
      repository_username             = ""
      repository_password             = ""

    },
    var.karpenter
  )

  values_karpenter = <<-VALUES
    settings:
        enablePodENI: true
    controller:
      resources:
        requests:
          cpu: 1
          memory: 1Gi
    serviceMonitor:
      enabled: ${local.kube-prometheus-stack["enabled"] || local.victoria-metrics-k8s-stack["enabled"]}
    VALUES

}

data "aws_iam_policy_document" "karpenter_additional" {
  count = local.karpenter["enabled"] ? 1 : 0

  statement {
    sid    = "Karpenter"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
      "kms:DescribeKey",
      "kms:CreateGrant",
      "kms:Describe",
      "kms:Get*",
      "kms:List*",
      "kms:RevokeGrant"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "karpenter_additional" {
  count       = local.karpenter["enabled"] ? 1 : 0
  name        = "${var.cluster-name}-karpenter-additional"
  description = "Karpenter additional policy for KMS"
  policy      = data.aws_iam_policy_document.karpenter_additional[0].json
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  create = local.karpenter["enabled"]

  cluster_name = var.cluster-name

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    KarpeneterAdditional         = local.karpenter["enabled"] ? aws_iam_policy.karpenter_additional[0].arn : ""
  }

  iam_role_use_name_prefix        = true
  irsa_oidc_provider_arn          = local.karpenter["irsa_oidc_provider_arn"]
  irsa_namespace_service_accounts = local.karpenter["irsa_namespace_service_accounts"]
  enable_irsa                     = true

  create_instance_profile = true
  create_iam_role = true
  create_node_iam_role = true

  tags = local.tags
}

resource "kubernetes_namespace" "karpenter" {
  count = local.karpenter["enabled"] && local.karpenter["create_ns"] ? 1 : 0

  metadata {
    labels = {
      name = local.karpenter["namespace"]
    }

    name = local.karpenter["namespace"]
  }
}

resource "helm_release" "karpenter" {
  count                 = local.karpenter["enabled"] ? 1 : 0
  repository            = local.karpenter["repository"]
  repository_username   = local.karpenter["repository_username"]
  repository_password   = local.karpenter["repository_password"]
  name                  = local.karpenter["name"]
  chart                 = local.karpenter["chart"]
  version               = local.karpenter["chart_version"]
  timeout               = local.karpenter["timeout"]
  force_update          = local.karpenter["force_update"]
  recreate_pods         = local.karpenter["recreate_pods"]
  wait                  = local.karpenter["wait"]
  atomic                = local.karpenter["atomic"]
  cleanup_on_fail       = local.karpenter["cleanup_on_fail"]
  dependency_update     = local.karpenter["dependency_update"]
  disable_crd_hooks     = local.karpenter["disable_crd_hooks"]
  disable_webhooks      = local.karpenter["disable_webhooks"]
  render_subchart_notes = local.karpenter["render_subchart_notes"]
  replace               = local.karpenter["replace"]
  reset_values          = local.karpenter["reset_values"]
  reuse_values          = local.karpenter["reuse_values"]
  skip_crds             = local.karpenter["skip_crds"]
  verify                = local.karpenter["verify"]
  values = [
    local.values_karpenter,
    local.karpenter["extra_values"]
  ]
  namespace = local.karpenter["create_ns"] ? kubernetes_namespace.karpenter.*.metadata.0.name[count.index] : local.karpenter["namespace"]

  set {
    name  = "serviceMonitor.enabled"
    value = "True"
  }

  set {
    name  = "settings.clusterName"
    value = var.cluster-name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = var.eks.cluster_endpoint
  }

  set {
    name  = "settings.featureGates.drift"
    value = "True"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter.iam_role_arn
  }

  set {
    name  = "settings.defaultInstanceProfile"
    value = module.karpenter.instance_profile_name
  }

  set {
    name  = "settings.interruptionQueueName"
    value = module.karpenter.queue_name
  }

}

resource "kubernetes_network_policy" "karpenter_default_deny" {
  count = local.karpenter["create_ns"] && local.karpenter["enabled"] && local.karpenter["default_network_policy"] ? 1 : 0

  metadata {
    name      = "${kubernetes_namespace.karpenter.*.metadata.0.name[count.index]}-default-deny"
    namespace = kubernetes_namespace.karpenter.*.metadata.0.name[count.index]
  }

  spec {
    pod_selector {
    }
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy" "karpenter_allow_namespace" {
  count = local.karpenter["create_ns"] && local.karpenter["enabled"] && local.karpenter["default_network_policy"] ? 1 : 0

  metadata {
    name      = "${kubernetes_namespace.karpenter.*.metadata.0.name[count.index]}-allow-namespace"
    namespace = kubernetes_namespace.karpenter.*.metadata.0.name[count.index]
  }

  spec {
    pod_selector {
    }

    ingress {
      from {
        namespace_selector {
          match_labels = {
            name = kubernetes_namespace.karpenter.*.metadata.0.name[count.index]
          }
        }
      }
    }

    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy" "karpenter_allow_monitoring" {
  count = local.karpenter["create_ns"] && local.karpenter["enabled"] && local.karpenter["default_network_policy"] ? 1 : 0

  metadata {
    name      = "${kubernetes_namespace.karpenter.*.metadata.0.name[count.index]}-allow-monitoring"
    namespace = kubernetes_namespace.karpenter.*.metadata.0.name[count.index]
  }

  spec {
    pod_selector {
    }

    ingress {
      ports {
        port     = "8080"
        protocol = "TCP"
      }

      from {
        namespace_selector {
          match_labels = {
            "${local.labels_prefix}/component" = "monitoring"
          }
        }
      }
    }

    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy" "karpenter_allow_control_plane" {
  count = local.karpenter["create_ns"] && local.karpenter["enabled"] && local.karpenter["default_network_policy"] ? 1 : 0

  metadata {
    name      = "${kubernetes_namespace.karpenter.*.metadata.0.name[count.index]}-allow-control-plane"
    namespace = kubernetes_namespace.karpenter.*.metadata.0.name[count.index]
  }

  spec {
    pod_selector {
      match_expressions {
        key      = "app.kubernetes.io/name"
        operator = "In"
        values   = ["karpenter"]
      }
    }

    ingress {
      ports {
        port     = "8443"
        protocol = "TCP"
      }

      dynamic "from" {
        for_each = local.karpenter["allowed_cidrs"]
        content {
          ip_block {
            cidr = from.value
          }
        }
      }
    }

    policy_types = ["Ingress"]
  }
}

resource "kubectl_manifest" "karpenter_nodepool" {
  count = local.karpenter["enabled"] ? 1 : 0

  yaml_body = local.karpenter["extra_nodepool_yaml"] != null ? local.karpenter["extra_nodepool_yaml"] : yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "default"
    }
    spec = {
      disruption = {
        budgets = [
          {
            nodes   = "20%"
            reasons = ["Underutilized"]
          }
        ]
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30m"
      }
      limits = {
        cpu = 250
      }
      template = {
        spec = {
          nodeClassRef = {
            name  = "default"
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
          }
          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot"]
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["c", "m", "r"]
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["2"]
            }
          ]
          nodeClassRef = {
            name  = "default"
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
          }
          tags = merge(
            {
              "Name"  = "karpenter-${var.cluster-name}"
            },
            local.tags
          )
          expireAfter = "168h"
        }
      }
    }
  })
  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_node_class" {
  count = local.karpenter["enabled"] ? 1 : 0

  yaml_body = try(local.karpenter.extra_nodeclass_yaml, null) != null ? local.karpenter.extra_nodeclass_yaml : yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      amiFamily        = local.karpenter["ami_family"]
      role             = module.karpenter.node_iam_role_name
      amiSelectorTerms = [
        {
          id = local.karpenter["ami_id"]
        }
      ]
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize = "4Gi"
            volumeType = local.karpenter["volumeType"]
            encrypted  = true
          }
        },
        {
          deviceName = "/dev/xvdb"
          ebs = {
            volumeSize = local.karpenter["volumeSize"]
            volumeType = local.karpenter["volumeType"]
            encrypted  = true
          }
        }
      ]
      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = var.cluster-name
          }
        }
      ]
      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = var.cluster-name
          }
        }
      ]
      metadataOptions = {
        httpPutResponseHopLimit = 2
      }
      tags = merge(
        {
          "karpenter.sh/discovery" = var.cluster-name
          "Name"                   = "karpenter-${var.cluster-name}"
        },
        local.tags
      )
    }
  })
  depends_on = [
    helm_release.karpenter
  ]
}

output "karpenter_iam" {
  value = module.karpenter
}