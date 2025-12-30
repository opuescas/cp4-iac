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

# ----------------------------------------------------------------
# 3. Operador IBM App Connect (v12.19)
# ----------------------------------------------------------------
resource "kubernetes_manifest" "app_connect_operator" {
  manifest = {
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "Subscription"
    metadata = {
      name      = "ibm-appconnect"
      namespace = "openshift-operators"
    }
    spec = {
      channel             = "v12.19" 
      installPlanApproval = "Automatic"
      name                = "ibm-appconnect"
      source              = "ibm-operator-catalog"
      sourceNamespace     = "openshift-marketplace"
    }
  }
}

# ----------------------------------------------------------------
# 4. Operador IBM MQ (v3.8)
# ----------------------------------------------------------------
resource "kubernetes_manifest" "mq_operator" {
  manifest = {
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "Subscription"
    metadata = {
      name      = "ibm-mq"
      namespace = "openshift-operators"
    }
    spec = {
      channel             = "v3.8"
      installPlanApproval = "Automatic"
      name                = "ibm-mq"
      source              = "ibm-operator-catalog"
      sourceNamespace     = "openshift-marketplace"
    }
  }
}

# ----------------------------------------------------------------
# 5. Operador IBM API Connect (v7.0)
# ----------------------------------------------------------------
resource "kubernetes_manifest" "api_connect_operator" {
  manifest = {
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "Subscription"
    metadata = {
      name      = "ibm-apiconnect"
      namespace = "openshift-operators"
    }
    spec = {
      channel             = "v7.0"
      installPlanApproval = "Automatic"
      name                = "ibm-apiconnect"
      source              = "ibm-operator-catalog"
      sourceNamespace     = "openshift-marketplace"
    }
  }
}

# 6. Operador IBM DataPower Gateway
resource "kubernetes_manifest" "datapower_operator" {
  manifest = {
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "Subscription"
    metadata = {
      name      = "datapower-operator"
      namespace = "openshift-operators"
    }
    spec = {
      channel             = "v1.17"
      installPlanApproval = "Automatic"
      name                = "datapower-operator"
      source              = "ibm-operator-catalog"
      sourceNamespace     = "openshift-marketplace"
    }
  }
}