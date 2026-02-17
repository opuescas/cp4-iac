resource "kubernetes_manifest" "ibm_operator_catalog" {
  manifest = {
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "CatalogSource"
    metadata = {
      name      = "ibm-operator-catalog"
      namespace = "openshift-marketplace"
    }
    spec = {
      displayName = "IBM Operator Catalog"
      publisher   = "IBM"
      sourceType  = "grpc"
      image       = "icr.io/cpopen/ibm-operator-catalog"
      updateStrategy = {
        registryPoll = {
          interval = "45m"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      manifest["spec"]["image"],
      manifest["metadata"]["annotations"],
      manifest["metadata"]["labels"],
    ]
  }
}

resource "kubernetes_manifest" "opencloud_operators_catalog" {
  manifest = {
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "CatalogSource"
    metadata = {
      name      = "opencloud-operators"
      namespace = "openshift-marketplace"
    }
    spec = {
      displayName = "IBMCS Operators"
      publisher   = "IBM"
      sourceType  = "grpc"
      image       = "docker.io/ibmcom/ibm-common-service-catalog:latest"
      updateStrategy = {
        registryPoll = {
          interval = "45m"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      manifest["spec"]["image"],
      manifest["metadata"]["annotations"],
      manifest["metadata"]["labels"],
    ]
  }
}