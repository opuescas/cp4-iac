# AUTO-GENERATED from yamls/DP/service.yaml
# YAML-HASH: 70e4d541ad7a226ad4a51e5526a214c3
resource "kubernetes_manifest" "gen_DP_service" {
  manifest = yamldecode(file("${path.module}/../../yamls/DP/service.yaml"))

}
