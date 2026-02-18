# ----------------------------------------------------------------
# DataPower Gateway – Namespace: cp4i-idg
# ----------------------------------------------------------------

# 1. Secret para el usuario admin de DataPower
resource "kubernetes_secret" "dp_admin_pass" {
  metadata {
    name      = "dp-admin-pass"
    namespace = "cp4i-idg"
  }

  data = {
    password = "@dm1nd@t@p0w3r"
  }

  type = "Opaque"
}

# 2. ConfigMap con la configuración web-mgmt / rest-mgmt
resource "kubernetes_config_map" "dp_web_mgmt" {
  metadata {
    name      = "dp-web-mgmt"
    namespace = "cp4i-idg"
  }

  data = {
    "web.cfg" = <<-EOF
      top; configure terminal;

      web-mgmt
        admin-state enabled
        local-address 0.0.0.0 9090
        ssl-config-type server
        idle-timeout 600
        no disable-csrf
        enable-sts
      exit

      rest-mgmt
        admin-state enabled
        local-address 0.0.0.0 5554
      exit

      write memory
    EOF
  }
}

# 3. DataPowerService CR
resource "kubernetes_manifest" "cdt_dp_service" {
  manifest = {
    apiVersion = "datapower.ibm.com/v1beta3"
    kind       = "DataPowerService"
    metadata = {
      name      = "cdt-dp-service"
      namespace = "cp4i-idg"
      labels = {
        "backup.datapower.ibm.com/component" = "datapowerservice"
      }
    }
    spec = {
      version  = "10.6-cd"
      replicas = 1
      license = {
        accept  = true
        license = "L-LQQV-WT4TTD"
        use     = "nonproduction"
      }
      resources = {
        limits = {
          memory = "4Gi"
        }
        requests = {
          cpu    = "1"
          memory = "4Gi"
        }
      }
      domains = [
        {
          name = "default"
          dpApp = {
            config = ["dp-web-mgmt"]
          }
        }
      ]
      livenessProbe = {
        httpGet = {
          path   = "/healthz"
          port   = 7879
          scheme = "HTTP"
        }
        initialDelaySeconds = 60
        timeoutSeconds      = 5
        periodSeconds       = 10
        failureThreshold    = 12
      }
      readinessProbe = {
        httpGet = {
          path   = "/healthz"
          port   = 7879
          scheme = "HTTP"
        }
        initialDelaySeconds = 30
        timeoutSeconds      = 5
        periodSeconds       = 5
        failureThreshold    = 24
      }
      users = [
        {
          name           = "admin"
          accessLevel    = "privileged"
          passwordSecret = "dp-admin-pass"
        }
      ]
    }
  }

  depends_on = [
    kubernetes_secret.dp_admin_pass,
    kubernetes_config_map.dp_web_mgmt,
  ]
}

# 4. Service para exponer management (web-mgmt + rest-mgmt)
resource "kubernetes_service" "dp_mgmt_svc" {
  metadata {
    name      = "dp-mgmt-svc"
    namespace = "cp4i-idg"
  }

  spec {
    selector = {
      "statefulset.kubernetes.io/pod-name" = "cdt-dp-service-0"
    }

    port {
      name        = "web-mgmt"
      port        = 9090
      target_port = 9090
    }

    port {
      name        = "rest-mgmt"
      port        = 5554
      target_port = 5554
    }

    type = "ClusterIP"
  }
}

# 5. Route para la consola web de DataPower
resource "kubernetes_manifest" "dp_webui_route" {
  manifest = {
    apiVersion = "route.openshift.io/v1"
    kind       = "Route"
    metadata = {
      name      = "dp-webui"
      namespace = "cp4i-idg"
    }
    spec = {
      to = {
        kind = "Service"
        name = "dp-mgmt-svc"
      }
      port = {
        targetPort = "web-mgmt"
      }
      tls = {
        termination = "passthrough"
      }
    }
  }

  depends_on = [kubernetes_service.dp_mgmt_svc]
}
