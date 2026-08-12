# AUTO-GENERATED from yamls/NEXUS/secret.yaml
# YAML-HASH: 4308d8b8b07f859dacc7a36f56834755
resource "kubernetes_manifest" "gen_NEXUS_secret" {
  manifest = yamldecode(file("${path.module}/../../yamls/NEXUS/secret.yaml"))

  computed_fields = [
    "data",
    "stringData",
    "metadata.annotations",
    "metadata.labels"
  ]
}
