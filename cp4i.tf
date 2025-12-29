resource "kubernetes_manifest" "platform_navigator" {
  depends_on = [
    kubernetes_manifest.cp4i_operator,
    kubernetes_manifest.common_service,
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