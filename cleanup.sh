#!/usr/bin/env bash

# Directorio de logs organizado
LOG_DIR="logs"
mkdir -p "$LOG_DIR"
TIMESTAMP_FILE=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${LOG_DIR}/cp4i_execution_${TIMESTAMP_FILE}.log"

# Colores para terminal
BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Función para obtener la hora actual
get_now() { date +"[%Y-%m-%d %H:%M:%S]"; }

# --- FUNCIONES DE LOGGING ---

log_header() {
    local TITLE=$1
    echo -e "\n\n================================================================================" >> "$LOG_FILE"
    echo "  $(get_now)  $TITLE" >> "$LOG_FILE"
    echo "================================================================================" >> "$LOG_FILE"
    echo -e "\n${BLUE}>>> $TITLE${NC}"
}

log_step() {
    local STEP=$1
    echo -e "\n$(get_now) --- $STEP ---" | tee -a "$LOG_FILE"
}

log() {
    echo -e "$(get_now) $1" | tee -a "$LOG_FILE"
}

filter_ansi() { 
    sed -e 's/\x1b\[[0-9;]*[mGJK]//g' -e 's/\x1b\[[0-9;]*[ABCDEFHJKST]//g'
}

# --- FUNCIONES DE DIAGNÓSTICO Y LIMPIEZA ---

inspect_cluster_state() {
    local PHASE="$1"
    log_header "INSPECCIÓN DE ESTADO ($PHASE)"
    oc get installplan -A -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,APPROVAL:.spec.approval,PHASE:.status.phase | grep -E "Manual|RequiresApproval" >> "$LOG_FILE" 2>&1 || log "No hay planes bloqueados."
    oc get platformnavigator -n cp4i >> "$LOG_FILE" 2>&1 || log "Navigator no encontrado."
}

run_deep_cleanup() {
    log_header "LIMPIEZA AGRESIVA CON TIMEOUT (ANTI-BLOQUEOS)"
    
    log_step "Matando procesos previos"
    killall -9 oc terraform 2>/dev/null || true
    
    log_step "Parcheando Finalizers (Forzado)"
    oc patch namespace cp4i --type=merge -p '{"metadata":{"finalizers":null}}' --request-timeout=10s >> "$LOG_FILE" 2>&1 || true
    # Nota: No borramos ibm-common-services para evitar conflictos si ya existe uno válido, 
    # pero si necesitas reinstalar desde cero, descomenta la siguiente línea:
    oc patch namespace ibm-common-services --type=merge -p '{"metadata":{"finalizers":null}}' --request-timeout=10s >> "$LOG_FILE" 2>&1 || true

    log_step "Eliminando OperandRequests (Sin esperar)"
    oc delete operandrequest --all -A --wait=false --grace-period=0 2>/dev/null
    
    log_step "Limpiando Suscripciones y CSVs"
    # Esto limpia suscripciones viejas para que no haya conflicto de versiones (ODLM)
    oc delete subscription --all -n openshift-operators | grep ibm >> "$LOG_FILE" 2>&1 || true
    oc get csv -n openshift-operators | grep -E "ibm|odlm|common-service" | awk '{print $1}' | xargs -L 1 oc delete csv -n openshift-operators --wait=false 2>/dev/null

    log_step "Borrando Namespaces de Aplicación"
    oc delete namespace cp4i ibm-common-services --grace-period=0 --force --wait=false 2>/dev/null
    
    log "Esperando estabilización del API (10s)..."
    sleep 10
}

# --- FUNCIÓN INTELIGENTE: AUTO IMPORTAR ---
# Esto evita el error "resource already exists" si los catálogos ya están en el cluster
auto_import_catalogs() {
    log_step "Verificando catálogos existentes para importar al estado..."

    # 1. IBM Operator Catalog
    if oc get catalogsource ibm-operator-catalog -n openshift-marketplace >/dev/null 2>&1; then
        log "ℹ️  'ibm-operator-catalog' ya existe. Importando a Terraform..."
        terraform import -no-color kubernetes_manifest.ibm_operator_catalog "apiVersion=operators.coreos.com/v1alpha1,kind=CatalogSource,namespace=openshift-marketplace,name=ibm-operator-catalog" >> "$LOG_FILE" 2>&1 || true
    else
        log "El catálogo 'ibm-operator-catalog' no existe, Terraform lo creará."
    fi

    # 2. Opencloud Operators Catalog
    if oc get catalogsource opencloud-operators -n openshift-marketplace >/dev/null 2>&1; then
        log "ℹ️  'opencloud-operators' ya existe. Importando a Terraform..."
        terraform import -no-color kubernetes_manifest.opencloud_operators_catalog "apiVersion=operators.coreos.com/v1alpha1,kind=CatalogSource,namespace=openshift-marketplace,name=opencloud-operators" >> "$LOG_FILE" 2>&1 || true
    else
        log "El catálogo 'opencloud-operators' no existe, Terraform lo creará."
    fi
}

# --- MENÚ PRINCIPAL ---
clear
echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}        IBM CP4I - GESTOR DE CICLO DE VIDA         ${NC}"
echo -e "${BLUE}====================================================${NC}"
echo "Directorio de logs: $LOG_DIR"
echo "Log actual: $LOG_FILE"
echo "----------------------------------------------------"
echo "1) INSTALACIÓN INTELIGENTE (Importa si existe + Apply)"
echo "2) DESINSTALACIÓN / DESTRABAR (Destroy + Finalizers)"
echo "3) SOLO LIMPIEZA MANUAL (Rescate rápido)"
echo "----------------------------------------------------"
read -p "Selecciona una opción [1-3]: " OPTION

case $OPTION in
  1)
    # Ejecutamos limpieza para asegurar que no haya basura de intentos fallidos (ODLM/Postgres)
    # Pero NO borramos los catálogos (marketplace)
    run_deep_cleanup
    
    log_header "TERRAFORM INIT"
    terraform init -no-color >> "$LOG_FILE" 2>&1
    
    # IMPORTANTE: Importamos catálogos existentes para evitar error de duplicados
    auto_import_catalogs
    
    log_step "Generando Plan"
    # Usamos -no-color para log limpio y tee para ver en pantalla y archivo
    if terraform plan -no-color -out=tfplan 2>&1 | filter_ansi | tee -a "$LOG_FILE"; then
        echo ""
        read -p "❓ ¿Deseas aplicar los cambios? (yes/no): " CONFIRM
        if [[ "$CONFIRM" == "yes" ]]; then
            log_step "Aplicando Configuración"
            terraform apply -no-color "tfplan" 2>&1 | filter_ansi | tee -a "$LOG_FILE"
            log "Esperando propagación del OLM (30s)..."
            sleep 30
            inspect_cluster_state "POST-INSTALL"
        fi
    else
        log "${RED}❌ El plan de Terraform falló. Revisa el log para detalles.${NC}"
        exit 1
    fi
    ;;
  2)
    inspect_cluster_state "PRE-DESTROY"
    log_header "FASE: TERRAFORM DESTROY (CON DESBLOQUEO DE FINALIZERS)"
    read -p "⚠️ ¿Seguro que deseas DESTRUIR todo? (yes/no): " CONFIRM
    if [[ "$CONFIRM" == "yes" ]]; then
        log_step "Iniciando Destroy (Monitoreando bloqueo de terminal)"
        terraform destroy -auto-approve -no-color 2>&1 | filter_ansi | tee -a "$LOG_FILE" &
        TF_PID=$!

        count=0
        while kill -0 $TF_PID 2>/dev/null && [ $count -lt 36 ]; do
            echo -n "."; sleep 5
            ((count++))
        done

        if kill -0 $TF_PID 2>/dev/null; then
            log "${RED}¡Terraform se quedó pegado! Forzando cierre del proceso...${NC}"
            kill -9 $TF_PID 2>/dev/null
        fi

        run_deep_cleanup
        log_step "Desinstalación y purga de finalizers completada."
    fi
    ;;
  3)
    run_deep_cleanup
    inspect_cluster_state "CLEANUP-DONE"
    ;;
  *)
    log "Opción inválida."
    ;;
esac

log_header "FIN DE LA SESIÓN"