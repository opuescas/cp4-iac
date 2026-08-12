# IBM Cloud Pak for Integration (CP4I) - Infraestructura como Código (IaC)

Este proyecto proporciona un framework automatizado para desplegar entornos de IBM Cloud Pak for Integration (CP4I) y componentes asociados (como Sonatype Nexus) en clústeres de Red Hat OpenShift utilizando Terraform.

---

## 🏗️ Arquitectura del Proyecto

El siguiente diagrama ilustra cómo se estructuran las definiciones de recursos, el proceso de automatización y su despliegue final en el clúster de OpenShift:

```mermaid
graph TD
    A[Definiciones de origen: yamls/] -->|YAMLs de Kubernetes| B[scripts/yaml_to_tf.sh]
    B -->|Genera mapeo .tf| C[stages/02-instances/]
    
    subgraph Terraform Stages
        D[stages/01-operators/] -->|Aplica| E[Operadores y CRDs]
        C -->|Aplica| F[Instancias de CP4I y Nexus]
    end

    subgraph Clúster OpenShift
        E -->|Registra| G[CRDs: API Connect, MQ, AppConnect, DataPower]
        F -->|Crea/Mapea| H[QueueManager, APIConnectCluster, Routes, Secrets]
    end
    
    I[start.sh Orquestador] -->|Controla el flujo, ejecuta imports y aplica hotfixes| D
    I -->|Controla el flujo| C
```

---

## 🎯 ¿Qué busca y qué logra este proyecto?

### Objetivos (Qué busca)
1. **Despliegues 100% Repetibles**: Evitar la configuración manual a través de la consola web de OpenShift.
2. **Abstracción de Recursos**: Permitir a los desarrolladores y administradores definir recursos en YAML estándar y mapearlos automáticamente a Terraform mediante un script transpilador (`yaml_to_tf.sh`).
3. **Resolución Automatizada de Errores Comunes**: Evitar que el despliegue falle o se detenga debido a bugs conocidos de los operadores de IBM (como bloqueos de reconciliación o fallos de sintaxis en plantillas).

### Resultados (Qué logra)
* **Instalación sin Fricción**: Despliegue secuencial de operadores e instancias con un solo comando.
* **Auto-sincronización de Recursos Existentes**: Ejecución de importaciones de estado inteligente (`terraform import`) para recursos que ya existían previamente en el clúster, evitando errores de duplicidad.
* **Hotfixes Integrados**: Detección y corrección en caliente de fallas de configuración.
* **Reporte de Credenciales**: Extracción automática de la URL de administración del Platform Navigator y las contraseñas temporales iniciales creadas por OLM.

---

## 🔄 Flujo de Ejecución y Orden de Despliegue

El despliegue está dividido en fases lógicas para cumplir con las dependencias de los recursos personalizados (Custom Resources) en Kubernetes:

```mermaid
sequenceDiagram
    participant U as Orquestador (start.sh)
    participant O as Etapa 1: Operadores
    participant C as Clúster (CRDs)
    participant I as Etapa 2: Instancias
    participant H as Diagnóstico y Hotfixes

    U->>U: Ejecuta scripts/yaml_to_tf.sh (Conversión de YAML a TF)
    U->>O: terraform apply (Fase de Operadores)
    O->>C: Crea Namespaces, CatalogSources y Subscriptions
    loop Espera inteligente de CRDs
        U->>C: Consulta oc get crd <componente>
    end
    U->>I: Sincronización inteligente (safe_import/terraform import)
    I->>C: Mapea recursos existentes para evitar conflictos de estado
    U->>I: terraform apply (Fase de Instancias y Nexus)
    I->>C: Despliega PlatformNavigator, APIConnect, MQ, Nexus Route/Secret
    U->>H: Aplica Hotfixes (APIC restart, Nginx Semicolon Fix)
    U->>C: Extrae credenciales temporales de ibm-common-services
    U->>U: Imprime URL de acceso en pantalla
```

---

## 📁 Estructura del Directorio

```
iac-cp4i/
├── yamls/                        # Manifiestos de Kubernetes originales (Fuente de Verdad)
│   ├── ACE/                      # Integración AppConnect (Dashboards)
│   ├── APIC/                     # Configuración del cluster de API Connect
│   ├── DP/                       # Configuración y Route de DataPower
│   └── NEXUS/                    # Configuración de Sonatype Nexus (Route, Secret, barauth)
├── stages/                       # Código de Terraform organizado por fases
│   ├── 01-operators/             # Terraform para namespaces, catálogos y operadores
│   └── 02-instances/             # Terraform para las instancias del Pak y automatizados
│       └── z_auto_*.tf           # Archivos generados dinámicamente
├── scripts/
│   └── yaml_to_tf.sh             # Transpilador de YAML a Kubernetes Manifest de Terraform
├── start.sh                      # Script orquestador principal
└── README.md                     # Esta documentación
```

---

## ⚙️ Integración con Sonatype Nexus

Para soportar el ciclo de vida de los paquetes de integración (`.bar`), se han integrado los recursos de Nexus bajo `yamls/NEXUS/`:

1. **Route de Nexus (`route.yaml`)**:
   Expone el servicio de Nexus en el namespace `openshift-operators` de manera dinámica.
2. **Secret de Credenciales (`secret.yaml`)**:
   Crea el secreto `setdbparams` en el namespace `cp4i` con el usuario administrador y la contraseña del servicio:
   * **Usuario**: `admin`
   * **Password**: `yWQZw-yLSAm-63fnq-QLqRY`
3. **Configuration barauth (`barauth.yaml`)**:
   Crea una configuración del tipo `barauth` llamada `nexus-barauth` en el namespace `cp4i`, que almacena las credenciales en formato Base64 para que IBM AppConnect pueda autenticarse contra Nexus de forma segura al descargar los archivos `.bar`.

---

## 🛡️ Diagnósticos y Parches (Hotfixes)

El script `./start.sh` aplica de manera automática dos parches necesarios para la estabilidad de la instalación:

### A. Desbloqueo del Operador de API Connect (`unblock_stuck_operator`)
En ocasiones, la instalación de API Connect se queda congelada al inicio esperando la creación de ConfigMaps. El script detecta esta condición y realiza un reinicio táctico del pod del operador `ibm-apiconnect` en el namespace `openshift-operators` para reactivar el ciclo de reconciliación.

### B. Corrección NGINX UI (`apply_nginx_hotfix`)
La versión 12.1.0 de API Connect tiene un error de sintaxis en el ConfigMap `mgmt-ui-nginx`, omitiendo un punto y coma (`;`) al final de una inyección de script:
* **Línea errónea**: `window.apiConnectCfg = $api_connect_cfg</script>'`
* **Línea corregida**: `window.apiConnectCfg = $api_connect_cfg</script>';`

El script analiza el ConfigMap, aplica la corrección y reinicia el pod del componente `management-ui` automáticamente.

---

## 🔍 ¿Cómo verificar el estado de los componentes?

Para validar manualmente que el entorno se ha desplegado correctamente, puedes utilizar los siguientes comandos:

### 1. Estado de los Operadores y CRDs
```bash
# Listar operadores instalados en el namespace de operadores
oc get csv -n openshift-operators

# Validar que los CRDs clave están registrados
oc get crd | grep -E "integration|apiconnect|mq|appconnect|datapower"
```

### 2. Estado de las Instancias del Cloud Pak
```bash
# Verificar Platform Navigator, API Connect, MQ y DataPower
oc get platformnavigator,apiconnectcluster,dashboard,queuemanager,datapowerservice -n cp4i
```

### 3. Estado de los Recursos de Nexus
```bash
# Verificar la ruta expuesta para Nexus
oc get route nexus -n openshift-operators

# Verificar el secreto de credenciales
oc get secret setdbparams -n cp4i -o yaml

# Verificar la configuración de barauth
oc get configuration nexus-barauth -n cp4i -o yaml
```

### 4. Credenciales de Acceso
Para extraer manualmente la contraseña de administrador inicial en caso de pérdida:
```bash
oc extract secret/integration-admin-initial-temporary-credentials -n ibm-common-services --to=-
```