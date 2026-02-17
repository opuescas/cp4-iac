# 1. Namespace principal donde instalas CP4I (Navigator)
resource "kubernetes_namespace" "cp4i" {
  metadata {
    name = "cp4i"
  }
}

# 2. Namespace de Servicios Comunes (Faltante)
resource "kubernetes_namespace" "ibm_common_services" {
  metadata {
    name = "ibm-common-services"
    # Aquí va la anotación manual que antes hacías con 'oc annotate'
    annotations = {
      "cp4i.ibm.com/ui-extension" = "true"
    }
  }
}

# 3. Namespace para DataPower Gateway
resource "kubernetes_namespace" "cp4i_idg" {
  metadata {
    name = "cp4i-idg"
  }
}