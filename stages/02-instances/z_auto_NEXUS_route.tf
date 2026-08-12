# AUTO-GENERATED from yamls/NEXUS/route.yaml
# YAML-HASH: 268b03804b2e3ff6bba3fbf68ad366b5
resource "kubernetes_manifest" "gen_NEXUS_route" {
  manifest = yamldecode(file("${path.module}/../../yamls/NEXUS/route.yaml"))
}
