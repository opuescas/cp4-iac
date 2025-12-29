resource "kubernetes_manifest" "fs_operator" {
  depends_on = [kubernetes_manifest.ibm_operator_catalog]
  manifest = {
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "Subscription"
    metadata = {
      name      = "ibm-common-service-operator"
      namespace = "openshift-operators"
    }
    spec = {
      channel             = "v4.6"
      # ESTO es lo que hace que el botón "Approve" desaparezca y lo haga solo
      installPlanApproval = "Automatic" 
      name                = "ibm-common-service-operator"
      source              = "ibm-operator-catalog"
      sourceNamespace     = "openshift-marketplace"
    }
  }
}

resource "kubernetes_manifest" "cp4i_operator" {
  depends_on = [kubernetes_manifest.ibm_operator_catalog]
  manifest = {
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "Subscription"
    metadata = {
      name      = "ibm-integration-platform-navigator"
      namespace = "openshift-operators"
    }
    spec = {
      channel             = "v8.2"
      installPlanApproval = "Automatic"
      name                = "ibm-integration-platform-navigator"
      source              = "ibm-operator-catalog"
      sourceNamespace     = "openshift-marketplace"
    }
  }
}