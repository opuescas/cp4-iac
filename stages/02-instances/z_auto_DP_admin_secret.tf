# AUTO-GENERATED from yamls/DP/admin-secret.yaml
# YAML-HASH: 520294390ec3adfc1bebe7a6f789c437
resource "kubernetes_manifest" "gen_DP_admin_secret" {
  manifest = yamldecode(file("${path.module}/../../yamls/DP/admin-secret.yaml"))
}
