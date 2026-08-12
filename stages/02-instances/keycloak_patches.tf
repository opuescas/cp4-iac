# ----------------------------------------------------------------
# 1. Buscar dinámicamente el IntegrationKeycloakClient de Platform UI
# ----------------------------------------------------------------
data "kubernetes_resources" "platform_navigator_clients" {
  api_version    = "keycloak.integration.ibm.com/v1beta1"
  kind           = "IntegrationKeycloakClient"
  namespace      = "ibm-common-services"
}

# ----------------------------------------------------------------
# 2. Aplicar el parche al cliente dinámico de la Platform UI
# ----------------------------------------------------------------
resource "kubernetes_manifest" "patch_platform_navigator_keycloak_client" {
  count = length(data.kubernetes_resources.platform_navigator_clients.objects) > 0 ? 1 : 0

  manifest = {
    apiVersion = "keycloak.integration.ibm.com/v1beta1"
    kind       = "IntegrationKeycloakClient"
    metadata = {
      name      = data.kubernetes_resources.platform_navigator_clients.objects[0].metadata.name
      namespace = "ibm-common-services"
    }
    spec = {
      client = {
        attributes = {
          "allow.token.introspection.without.audience.check" = "true"
        }
        protocolMappers = [
          {
            name           = "audience-mapper"
            protocol       = "openid-connect"
            protocolMapper = "oidc-audience-mapper"
            config = {
              "included.client.audience"  = data.kubernetes_resources.platform_navigator_clients.objects[0].metadata.name
              "id.token.claim"            = "false"
              "access.token.claim"        = "true"
              "introspection.token.claim" = "true"
            }
          }
        ]
      }
    }
  }
}

# ----------------------------------------------------------------
# 3. Buscar dinámicamente el IntegrationKeycloakClient de App Connect Dashboard
# ----------------------------------------------------------------
data "kubernetes_resources" "dashboard_clients" {
  api_version    = "keycloak.integration.ibm.com/v1beta1"
  kind           = "IntegrationKeycloakClient"
  namespace      = "cp4i"
}

locals {
  dashboard_client_names = [
    for r in data.kubernetes_resources.dashboard_clients.objects :

    r.metadata.name if startswith(r.metadata.name, "dash-cp4i-")
  ]
  dashboard_client_name = length(local.dashboard_client_names) > 0 ? local.dashboard_client_names[0] : ""
}

# ----------------------------------------------------------------
# 4. Aplicar el parche al cliente dinámico del App Connect Dashboard
# ----------------------------------------------------------------
resource "kubernetes_manifest" "patch_dashboard_keycloak_client" {
  count = local.dashboard_client_name != "" ? 1 : 0

  manifest = {
    apiVersion = "keycloak.integration.ibm.com/v1beta1"
    kind       = "IntegrationKeycloakClient"
    metadata = {
      name      = local.dashboard_client_name
      namespace = "cp4i"
    }
    spec = {
      client = {
        attributes = {
          "client.use.lightweight.access.token.enabled"      = "false"
          "allow.token.introspection.without.audience.check" = "true"
        }
        protocolMappers = [
          {
            name           = "audience-mapper"
            protocol       = "openid-connect"
            protocolMapper = "oidc-audience-mapper"
            config = {
              "included.client.audience"  = local.dashboard_client_name
              "id.token.claim"            = "false"
              "access.token.claim"        = "true"
              "introspection.token.claim" = "true"
            }
          }
        ]
      }
    }
  }
}

# ----------------------------------------------------------------
# 5. Declarar y bloquear la Suscripción del operador de Keycloak
# ----------------------------------------------------------------
resource "kubernetes_manifest" "keycloak_operator_subscription" {
  manifest = {
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "Subscription"
    metadata = {
      name      = "rhbk-operator"
      namespace = "ibm-common-services"
    }
    spec = {
      channel             = "stable-v26"
      installPlanApproval = "Manual"
      name                = "rhbk-operator"
      source              = "redhat-operators"
      sourceNamespace     = "openshift-marketplace"
      startingCSV         = "rhbk-operator.v26.2.5-opr.1"
    }
  }
}

# ----------------------------------------------------------------
# 6. Limpieza automática de base de datos y autorecuperación 26.2
# ----------------------------------------------------------------
resource "null_resource" "cleanup_keycloak_obsolete_authenticators" {
  depends_on = [
    kubernetes_manifest.patch_platform_navigator_keycloak_client,
    kubernetes_manifest.patch_dashboard_keycloak_client,
    kubernetes_manifest.keycloak_operator_subscription
  ]

  provisioner "local-exec" {
    command = <<EOT
      echo "=== [TF POST-APPLY] Iniciando validación y limpieza de base de datos de Keycloak ==="
      
      # 1. Esperar a que el pod de base de datos esté listo (con un límite de 10 minutos)
      echo "Esperando a que PostgreSQL de Keycloak esté activo (límite de 10 minutos)..."
      COUNTER=0
      MAX_WAIT=120  # 120 * 5s = 600s (10 minutos)
      until oc get pods -n ibm-common-services -l cluster-name=keycloak-edb-cluster | grep -q "1/1"; do 
        if [ $COUNTER -ge $MAX_WAIT ]; then
          echo "❌ ERROR: Tiempo de espera agotado esperando a que PostgreSQL de Keycloak esté activo."
          exit 1
        fi
        sleep 5
        COUNTER=$((COUNTER + 1))
      done


      # 2. Extraer contraseña del secreto dinámicamente
      echo "Extrayendo credenciales de PostgreSQL..."
      DB_PASSWORD=$(oc get secret keycloak-edb-cluster-app -n ibm-common-services -o jsonpath='{.data.password}' | base64 --decode)

      # 3. Limpiar componentes obsoletos de Keycloak 26.4 usando SQL dinámico
      echo "Purgando componentes obsoletos de la base de datos de forma dinámica..."
      oc exec keycloak-edb-cluster-1 -n ibm-common-services -c postgres -- env PGPASSWORD="$DB_PASSWORD" psql -h localhost -U app -d keycloak -c "
        BEGIN;
        
        -- Crear tabla temporal con los IDs de configuración dinámicos
        CREATE TEMP TABLE temp_obsolete_configs AS 
        SELECT DISTINCT auth_config 
        FROM authentication_execution 
        WHERE authenticator IN ('conditional-credential', 'auth-recovery-authn-code-form') 
          AND auth_config IS NOT NULL;
        
        -- Borrar de authenticator_config_entry
        DELETE FROM authenticator_config_entry 
        WHERE authenticator_id IN (SELECT auth_config FROM temp_obsolete_configs);
        
        -- Romper relación foreign key en la tabla de ejecuciones
        UPDATE authentication_execution 
        SET auth_config = NULL 
        WHERE authenticator IN ('conditional-credential', 'auth-recovery-authn-code-form');
        
        -- Borrar de authenticator_config
        DELETE FROM authenticator_config 
        WHERE id IN (SELECT auth_config FROM temp_obsolete_configs);
        
        -- Borrar las ejecuciones en sí de la tabla principal
        DELETE FROM authentication_execution 
        WHERE authenticator IN ('conditional-credential', 'auth-recovery-authn-code-form');
        
        COMMIT;
      "

      # 4. Forzar reinicio de Keycloak para limpiar cachés internas
      echo "Reiniciando pod de Keycloak para refrescar cachés..."
      oc delete pod cs-keycloak-0 -n ibm-common-services --ignore-not-found=true
      
      echo "=== [TF POST-APPLY] Limpieza y sincronización de Keycloak finalizadas con éxito ==="
    EOT
  }
}



