# AUTO-GENERATED from yamls/DP/configmap.yaml
# YAML-HASH: 565aaeaac1302112054356a382845b2a
resource "kubernetes_manifest" "gen_DP_configmap" {
  manifest = yamldecode(file("${path.module}/../../yamls/DP/configmap.yaml"))

}
