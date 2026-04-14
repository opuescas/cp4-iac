# AUTO-GENERATED from yamls/ACE/int-dashboard.yaml
# YAML-HASH: 19f55270e24a8d672ca75b4b8182971a
resource "kubernetes_manifest" "gen_ACE_int_dashboard" {
  manifest = yamldecode(file("${path.module}/../../yamls/ACE/int-dashboard.yaml"))
}
