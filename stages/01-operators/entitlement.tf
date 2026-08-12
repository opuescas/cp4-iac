# =============================================================================
# IBM Entitlement Key - Prerequisito crítico para descargar imágenes de APIC
# =============================================================================
# Este secreto permite al operador de API Connect descargar imágenes de
# cp.icr.io (IBM Container Registry). Sin él, los pods del management
# de APIC (apim, lur, ldap, etc.) no pueden crearse.
#
# El entitlement key se obtiene en:
#   https://myibm.ibm.com/products-services/containerlibrary
#
# Se configura vía variable de entorno TF_VAR_ibm_entitlement_key
# o en terraform.tfvars (NO commitear en git).
# =============================================================================

variable "ibm_entitlement_key" {
  description = "IBM Entitlement Key para descargar imágenes de cp.icr.io"
  type        = string
  sensitive   = true
}

locals {
  entitlement_namespaces = [
    "cp4i",
    "ibm-common-services",
    "openshift-operators",
  ]
}

resource "kubernetes_secret" "ibm_entitlement_key" {
  for_each = toset(local.entitlement_namespaces)

  metadata {
    name      = "ibm-entitlement-key"
    namespace = each.key
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "cp.icr.io" = {
          username = "cp"
          password = var.ibm_entitlement_key
          auth     = base64encode("cp:${var.ibm_entitlement_key}")
        }
      }
    })
  }

  depends_on = [
    kubernetes_namespace.cp4i,
    kubernetes_namespace.ibm_common_services,
  ]

  lifecycle {
    # No recrear si ya existe (idempotente para re-ejecuciones mensuales)
    ignore_changes = [metadata[0].resource_version]
  }
}
