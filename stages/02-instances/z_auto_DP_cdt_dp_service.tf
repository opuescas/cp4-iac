# AUTO-GENERATED from yamls/DP/cdt-dp-service.yaml
# YAML-HASH: 7bc66349d74538538d415959f5ec6f5d
resource "kubernetes_manifest" "gen_DP_cdt_dp_service" {
  manifest = yamldecode(file("${path.module}/../../yamls/DP/cdt-dp-service.yaml"))

  computed_fields = [
    "spec.livenessProbe",
    "spec.readinessProbe",
    "metadata.annotations",
    "metadata.labels"
  ]
}
