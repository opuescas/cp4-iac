resource "kubernetes_namespace" "cp4i" {
  metadata {
    name = "cp4i"
  }

  lifecycle {
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations
    ]
  }
}