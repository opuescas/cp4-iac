# AUTO-GENERATED from yamls/ACE/int-dashboard.yaml
# YAML-HASH: 3540dab259a12d5d0b82255fa594a3aa
resource "kubernetes_manifest" "gen_ACE_int_dashboard" {
  manifest = yamldecode(file("${path.module}/../../yamls/ACE/int-dashboard.yaml"))

}
