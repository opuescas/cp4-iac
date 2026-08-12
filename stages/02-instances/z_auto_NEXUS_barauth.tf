# AUTO-GENERATED from yamls/NEXUS/barauth.yaml
# YAML-HASH: 17efa0c56f8a0ba99daa6a09994527bb
resource "kubernetes_manifest" "gen_NEXUS_barauth" {
  manifest = yamldecode(file("${path.module}/../../yamls/NEXUS/barauth.yaml"))
}
