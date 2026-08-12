# AUTO-GENERATED from yamls/DP/cdt-dp-service.yaml
# YAML-HASH: 7bc66349d74538538d415959f5ec6f5d
resource "kubernetes_manifest" "gen_DP_cdt_dp_service" {
  manifest = yamldecode(file("${path.module}/../../yamls/DP/cdt-dp-service.yaml"))

  lifecycle {
    ignore_changes = [
      object.spec.livenessProbe,
      object.spec.readinessProbe,
      object.metadata.annotations,
      object.metadata.labels,
    ]
  }
}
