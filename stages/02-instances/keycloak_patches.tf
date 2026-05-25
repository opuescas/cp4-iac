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
  count = length(data.kubernetes_resources.platform_navigator_clients.resources) > 0 ? 1 : 0

  manifest = {
    apiVersion = "keycloak.integration.ibm.com/v1beta1"
    kind       = "IntegrationKeycloakClient"
    metadata = {
      name      = data.kubernetes_resources.platform_navigator_clients.resources[0].metadata.name
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
              "included.client.audience"  = data.kubernetes_resources.platform_navigator_clients.resources[0].metadata.name
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
# 3. Aplicar el parche al cliente de App Connect Dashboard (Nombre Fijo)
# ----------------------------------------------------------------
resource "kubernetes_manifest" "patch_dashboard_keycloak_client" {
  manifest = {
    apiVersion = "keycloak.integration.ibm.com/v1beta1"
    kind       = "IntegrationKeycloakClient"
    metadata = {
      name      = "dash-cp4i-db-02-production-2-fcdd9"
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
              "included.client.audience"  = "dash-cp4i-db-02-production-2-fcdd9"
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
