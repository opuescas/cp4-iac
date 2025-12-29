resource "kubernetes_namespace" "ibm_common_services" {
  metadata {
    name = "ibm-common-services"
    annotations = {
      "cp4i.ibm.com/ui-extension" = "true"
    }
  }
}

resource "kubernetes_manifest" "common_service" {
  manifest = {
    apiVersion = "operator.ibm.com/v3"
    kind       = "CommonService"
    metadata = {
      # El Navigator busca este nombre exacto
      name      = "common-service" 
      namespace = "ibm-common-services"
    }
    spec = {
      size = "medium"
      # Forzamos la ubicación de los servicios para evitar el error de namespace
      operatorNamespace = "ibm-common-services"
      servicesNamespace = "ibm-common-services"
    }
  }
}