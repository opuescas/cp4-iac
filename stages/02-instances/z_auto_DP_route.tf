# AUTO-GENERATED from yamls/DP/route.yaml
# YAML-HASH: 4ed6e5cff4346c33fd581222afe009b8
resource "kubernetes_manifest" "gen_DP_route" {
  manifest = yamldecode(file("${path.module}/../../yamls/DP/route.yaml"))
}
