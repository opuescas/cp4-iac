# IBM Cloud Pak for Integration (CP4I) - Infraestructura como Código (IaC)

Este proyecto proporciona la funcionalidad automatizada para desplegar entornos de IBM Cloud Pak for Integration (CP4I) en un clúster de Red Hat OpenShift utilizando Terraform.

## Funcionalidad Principal

- **Conversión de YAML a Terraform**: Utiliza el script `yaml_to_tf.sh` para convertir de forma automatizada las definiciones de recursos de Kubernetes (archivos YAML) en recursos manipulables desde Terraform.
- **Despliegue en 2 Etapas**: 
  - **Etapa 1 (`stages/01-operators`)**: Instalación de los Operadores necesarios (Cert Manager, Common Services, CP4I, MQ, AppConnect, API Connect, DataPower) y despliegue de los CRDs (Custom Resource Definitions).
  - **Etapa 2 (`stages/02-instances`)**: Creación de las instancias de los componentes de CP4I (Platform Navigator, API Connect Cluster, Queue Manager, Dashboard, DataPower Service, etc.).
- **Diagnóstico y Auto-Corrección (Hotfixes)**: El script general de orquestación (`start.sh`) cuenta con funciones integradas para:
  - Destrabar pods bloqueados del operador de API Connect forzando su reconciliación.
  - Aplicar un parcheo de sintaxis en el archivo de configuración interno NGINX de la UI (`mgmt-ui-nginx`).
  - Auto-sincronizar e importar recursos que hayan sido creados previamente.
- **Validación y Extracción de Credenciales**: Al finalizar el proceso, el proyecto valida el estado subyacente de cada tecnología y extrae de forma segura las credenciales iniciales para ingresar al Panel del Platform Navigator.

---

## Orden de Ejecución para Levantar los Entornos

Existen dos alternativas para ejecutar el despliegue: utilizando el orquestador interactivo recomendado o aplicando las instrucciones de Terraform manualmente.

### Prerrequisitos
- Estar correctamente autenticado en el clúster de OpenShift (mediante `oc login ...`).
- Tener la variable de entorno `$KUBECONFIG` configurada en tu sesión, o validada en el directorio local.
- Software requerido: `terraform` (CLI), `oc` (OpenShift Client CLI) y bash (macOS / Linux).

### Opción 1: Despliegue Automatizado (Recomendado)

El script `./start.sh` se encarga de manejar silenciosamente las fases, aplicar las importaciones sin que rompa el tfstate y corregir anomalías conocidas de los operadores.

1. Abre tu terminal en la raíz de este proyecto.
2. Brinda los permisos de ejecución en caso de no tenerlos (`chmod +x start.sh scripts/yaml_to_tf.sh`).
3. Inicializa el script y selecciona la primera opción:
   ```bash
   ./start.sh
   ```
   > Selecciona: **1) APLICAR (Install + Auto-Unblock + Hotfix)**
4. Observa el progreso. El script ejecutará automáticamente la conversión en bash, aplicará los manifiestos de la **Etapa 1**, hará una "espera inteligente" de los CRDs, y gatillará la **Etapa 2**. Posteriormente te revelará las credenciales.

### Opción 2: Despliegue Manual desde Terraform

Si prefieres obviar la automatización del menú e instanciar manualmente el código, sigue estricto este orden:

1. **Generación de Archivos TF**:
   Debes ejecutar obligatoriamente el convertidor en las carpetas de variables para transcribir el YAML al formato `.tf`.
   ```bash
   ./scripts/yaml_to_tf.sh
   ```

2. **Despliegue de Etapa 1 (Operadores)**:
   ```bash
   cd stages/01-operators
   terraform init
   terraform apply
   # Escribe 'yes' cuando te lo solicite.
   ```

3. **Verificación Estricta de CRDs**:
   No puedes avanzar sin que los CRDs clave sean aceptados por el clúster. Verifica que se listen de forma correcta:
   ```bash
   oc get crd platformnavigators.integration.ibm.com
   oc get crd apiconnectclusters.apiconnect.ibm.com
   oc get crd queuemanagers.mq.ibm.com
   ```

4. **Despliegue de Etapa 2 (Instancias)**:
   A diferencia del `start.sh`, aquí deberás estar atento a que recursos ya creados en OpenShift pueden entrar en conflicto con el tfstate, requiriendo en su defecto utilizar `terraform import`:
   ```bash
   cd ../02-instances
   terraform init
   terraform apply
   # Escribe 'yes' cuando te lo solicite.
   ```

5. **Post-Instalación**:
   Recuerda asegurarte de actualizar o aceptar licencias usando `oc patch commonservice common-service` manual en caso quede pendiente.

---

## Funciones Extra

- **Eliminación Total (Destroy)**: Si abres el `./start.sh`, la **Opción 2** está configurada para realizar un plan de destrucción general con `terraform destroy`, desinstalando de raíz ambas fases (instancias y luego operadores).
- **Recuperación de Panel**: Ante una pérdida de acceso, puedes recurrir al `./start.sh` con la **Opción 3**, que realizará la tarea única de re-escanear las rutas (Routes) de OpenShift y extraer la Password provista en los secrets, listándola amigablemente por pantalla.