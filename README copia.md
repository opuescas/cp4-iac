# CP4I Terraform Installation (OpenShift)

Este repositorio instala **IBM Cloud Pak for Integration (CP4I)** sobre OpenShift usando **Terraform**, sin depender de la consola web.

Incluye:
- IBM Foundational Services
- Platform Navigator
- Operadores requeridos
- Namespaces

---

## 📦 Requisitos

### Local
- Terraform >= 1.5
- OpenShift CLI (`oc`)
- Acceso al clúster OpenShift (login activo)

### Clúster
- OpenShift 4.x
- Acceso a `ibm-operator-catalog`
- StorageClass por defecto configurado

---

## 🔐 Acceso al clúster

Terraform usa el **kubeconfig local**.

Verifica:
```bash
oc whoami
oc status
