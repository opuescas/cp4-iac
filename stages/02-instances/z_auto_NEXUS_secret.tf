# AUTO-GENERATED from yamls/NEXUS/secret.yaml
# YAML-HASH: ab30eb77c853bb337edae39a91fc503d
resource "kubernetes_manifest" "gen_NEXUS_secret" {
  manifest = yamldecode(file("${path.module}/../../yamls/NEXUS/secret.yaml"))
}
