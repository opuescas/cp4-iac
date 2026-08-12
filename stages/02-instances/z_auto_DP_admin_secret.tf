# AUTO-GENERATED from yamls/DP/admin-secret.yaml
# YAML-HASH: 4a59a09d2266b2d76822fbeb4b85aad8
resource "kubernetes_manifest" "gen_DP_admin_secret" {
  manifest = yamldecode(file("${path.module}/../../yamls/DP/admin-secret.yaml"))

  computed_fields = [
    "data",
    "stringData",
    "metadata.annotations",
    "metadata.labels"
  ]
}
