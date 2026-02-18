resource "kubernetes_manifest" "platform_navigator" {
  # dependencies handled in stage 1

  manifest = {
    apiVersion = "integration.ibm.com/v1beta1"
    kind       = "PlatformNavigator"
    metadata = {
      name      = "integration-quickstart-cdt"
      namespace = "cp4i"
      labels = {
        "backup.integration.ibm.com/component" = "platformnavigator"
      }
    }
    spec = {
      version  = "16.1.3"
      replicas = 1
      license = {
        accept  = true
        license = "L-SJZL-NMUUCT"
      }
    #   requestIbmServices = {
    #   namespace = "ibm-common-services"
    # }
    }
  }
}

resource "kubernetes_manifest" "apic_cluster" {
  manifest = yamldecode(file("${path.module}/../../yamls/APIC/cluster-medium.yaml"))
}

# 1. ConfigMap para seguridad web de MQ
resource "kubernetes_config_map" "mqwebuserconfigmap" {
  metadata {
    name      = "mqwebuserconfigmap"
    namespace = "cp4i"
  }

  data = {
    "mqwebuser.xml" = <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<server>
  <featureManager>
    <feature>appSecurity-2.0</feature>
    <feature>basicAuthenticationMQ-1.0</feature>
  </featureManager>
  <enterpriseApplication id="com.ibm.mq.console">
    <application-bnd>
      <security-role name="MQWebAdmin">
        <group name="MQWebAdminGroup" realm="defaultRealm"/>
      </security-role>
    </application-bnd>
  </enterpriseApplication>
  <basicRegistry id="basic" realm="defaultRealm">
    <user name="mqadmin" password="m9adm1n$"/>
    <group name="MQWebAdminGroup">
      <member name="mqadmin"/>
    </group>
  </basicRegistry>
  <sslDefault sslRef="mqDefaultSSLConfig"/>
</server>
EOF
  }
}

# 2. Instancia del Queue Manager
resource "kubernetes_manifest" "qm1_cdt" {
  manifest = {
    apiVersion = "mq.ibm.com/v1beta1"
    kind       = "QueueManager"
    metadata = {
      name      = "qm1-cdt"
      namespace = "cp4i"
      annotations = {
        "com.ibm.mq/write-defaults-spec" = "false"
      }
    }
    spec = {
      version = "9.4.4.0-r4"
      license = {
        accept  = true
        license = "L-SJZL-NMUUCT"
        use     = "Production"
      }
      queueManager = {
        name = "CUSTOM"
        availability = {
          type = "NativeHA"
        }
        metrics = {
          enabled = true
          tls = {
            provider = "openshift"
          }
        }
      }
      web = {
        enabled = true
        console = {
          authentication = { provider = "manual" }
          authorization  = { provider = "manual" }
        }
        manualConfig = {
          configMap = {
            name = "mqwebuserconfigmap"
          }
        }
      }
    }
  }
  depends_on = [kubernetes_config_map.mqwebuserconfigmap]
}
# ----------------------------------------------------------------
# Cert Manager Instance (Moved from Stage 1)
# ----------------------------------------------------------------
resource "kubernetes_manifest" "cert_manager_cluster" {
  manifest = {
    apiVersion = "operator.openshift.io/v1alpha1"
    kind       = "CertManager"
    metadata = {
      name = "cluster"
    }
    spec = {
      managementState = "Managed"
    }
  }
}

# ----------------------------------------------------------------
# App Connect Dashboard (from yamls/int-dashboard.yaml)
# ----------------------------------------------------------------
/*
resource "kubernetes_manifest" "app_connect_dashboard" {
  manifest = {
    apiVersion = "appconnect.ibm.com/v1beta1"
    kind       = "Dashboard"
    metadata = {
      name      = "dshb-cdt"
      namespace = "cp4i"
      labels = {
        "backup.appconnect.ibm.com/component" = "dashboard"
      }
    }
    spec = {
      version     = "13.0.6"
      replicas    = 3
      displayMode = "IntegrationRuntimes"
      license = {
        accept  = true
        license = "L-CKFT-S6CHZW"
        use     = "CloudPakForIntegrationNonProduction"
      }
      api = {
        enabled = true
      }
      authentication = {
        integrationKeycloak = {
          enabled = true
        }
      }
      authorization = {
        integrationKeycloak = {
          enabled = true
        }
      }
      storage = {
        size  = "5Gi"
        type  = "persistent-claim"
        class = "ocs-storagecluster-cephfs"
      }
      pod = {
        containers = {
          content-server = {
            resources = {
              limits = {
                memory = "512Mi"
              }
              requests = {
                cpu    = "50m"
                memory = "50Mi"
              }
            }
          }
          control-ui = {
            resources = {
              limits = {
                memory = "512Mi"
              }
              requests = {
                cpu    = "50m"
                memory = "125Mi"
              }
            }
          }
        }
      }
      auditLog = {
        disabled = true
      }
    }
  }
}
*/
