# AUTO-GENERATED from yamls/ACE/int-dashboard.yaml
# YAML-HASH: 6708df8a8b61cbc681c3125247aa0bc0
resource "kubernetes_manifest" "gen_ACE_int_dashboard" {
  manifest = yamldecode(file("${path.module}/../../yamls/ACE/int-dashboard.yaml"))
}
