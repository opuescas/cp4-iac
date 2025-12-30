resource "kubernetes_manifest" "platform_navigator" {
  depends_on = [
    kubernetes_manifest.cp4i_operator,
    kubernetes_namespace.cp4i
  ]

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
  manifest = {
    apiVersion = "apiconnect.ibm.com/v1beta1"
    kind       = "APIConnectCluster"
    metadata = {
      name      = "large-cdt"
      namespace = "cp4i"
      annotations = {
        "apiconnect-operator/cp4i" = "true"
      }
      labels = {
        "backup.apiconnect.ibm.com/component" = "apiconnectcluster"
      }
    }
    spec = {
      version = "12.1.0.0"
      profile = "n3xc16.m64" # Perfil de Alta Disponibilidad (Requiere muchos recursos)
      license = {
        accept  = true
        license = "L-PDZK-TWDH97"
        metric  = "VIRTUAL_PROCESSOR_CORE"
        use     = "production"
      }
      storageClassName = "ocs-storagecluster-ceph-rbd" # Asegurate que esta SC exista
      portal = {
        mtlsValidateClient = true
      }
      analytics = {
        mtlsValidateClient = true
      }
    }
  }
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