# AUTO-GENERATED from yamls/DP/admin-secret.yaml
# YAML-HASH: 4a59a09d2266b2d76822fbeb4b85aad8
resource "kubernetes_manifest" "gen_DP_admin_secret" {
  manifest = yamldecode(file("${path.module}/../../yamls/DP/admin-secret.yaml"))

  lifecycle {
    ignore_changes = [
      object.data,
      object.stringData,
      object.metadata.annotations,
      object.metadata.labels,
    ]
  }
}
