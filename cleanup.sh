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

check_catalogs_health() {
    log_step "Verificando salud de Catálogos (CatalogSources)"
    # Esperamos hasta 60s a que los catálogos estén READY
    local retries=0
    while [ $retries -lt 12 ]; do
        local failed_catalogs=$(oc get catalogsource -n openshift-marketplace -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.connectionState.lastObservedState}{"\n"}{end}' | grep -v "READY")
        
        if [ -z "$failed_catalogs" ]; then
            log "${GREEN}✅ Todos los catálogos están saludables.${NC}"
            return 0
        fi
        
        echo -n "."
        sleep 5
        ((retries++))
    done
    
    log "${RED}❌ Error: Hay catálogos fallando. Terraform fallará si esto no se arregla.${NC}"
    oc get catalogsource -n openshift-marketplace >> "$LOG_FILE"
    # Mostramos logs del pod fallido para debug rápido
    local bad_pod=$(oc get pods -n openshift-marketplace -o name | grep postgres)
    if [ ! -z "$bad_pod" ]; then
        log "Logs del catálogo Postgres:"
        oc logs $bad_pod -n openshift-marketplace --tail=20 2>&1 | tee -a "$LOG_FILE"
    fi
    return 1
}

inspect_cluster_state() {
    local PHASE="$1"
    log_header "INSPECCIÓN DE ESTADO ($PHASE)"
    
    log_step "Detectando InstallPlans bloqueados (Manual/RequiresApproval)"
    oc get installplan -A -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,APPROVAL:.spec.approval,PHASE:.status.phase | grep -E "Manual|RequiresApproval" >> "$LOG_FILE" 2>&1 || log "No hay planes bloqueados."
    
    log_step "Estado de PlatformNavigator en cp4i"
    oc get platformnavigator -n cp4i >> "$LOG_FILE" 2>&1 || log "No encontrado."
    
    log_step "OperandRequests (Componentes atascados)"
    oc get operandrequest -A >> "$LOG_FILE" 2>&1
    
    log_step "Estado de Suscripciones (Errores de resolución)"
    oc get subscription -A -o custom-columns=NAME:.metadata.name,STATUS:.status.state,REASON:.status.reason >> "$LOG_FILE" 2>&1
}

run_deep_cleanup() {
    log_header "LIMPIEZA AGRESIVA CON TIMEOUT (ANTI-BLOQUEOS)"
    
    log_step "Matando procesos previos"
    killall -9 oc terraform 2>/dev/null || true
    
    log_step "Parcheando Finalizers (Forzado)"
    oc patch namespace cp4i --type=merge -p '{"metadata":{"finalizers":null}}' --request-timeout=10s >> "$LOG_FILE" 2>&1 || true
    oc patch namespace ibm-common-services --type=merge -p '{"metadata":{"finalizers":null}}' --request-timeout=10s >> "$LOG_FILE" 2>&1 || true

    log_step "Eliminando OperandRequests (Sin esperar)"
    oc delete operandrequest --all -A --wait=false --grace-period=0 2>/dev/null
    
    log_step "Limpiando Suscripciones y CSVs"
    oc delete subscription --all -n openshift-operators | grep ibm >> "$LOG_FILE" 2>&1 || true
    oc get csv -n openshift-operators | grep -E "ibm|cloud-native-postgresql" | awk '{print $1}' | xargs -L 1 oc delete csv -n openshift-operators --wait=false 2>/dev/null

    log_step "Borrando Namespaces"
    oc delete namespace cp4i ibm-common-services --grace-period=0 --force --wait=false 2>/dev/null
    
    log "Esperando estabilización del API (15s)..."
    sleep 15
}

# --- MENÚ PRINCIPAL ---
clear
echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}        IBM CP4I - GESTOR DE CICLO DE VIDA         ${NC}"
echo -e "${BLUE}====================================================${NC}"
echo "Directorio de logs: $LOG_DIR"
echo "Log actual: $LOG_FILE"
echo "----------------------------------------------------"
echo "1) INSTALACIÓN COMPLETA (Limpieza + Apply)"
echo "2) DESINSTALACIÓN / DESTRABAR (Destroy + Finalizers)"
echo "3) SOLO LIMPIEZA MANUAL (Rescate rápido)"
echo "----------------------------------------------------"
read -p "Selecciona una opción [1-3]: " OPTION

case $OPTION in
  1)
    run_deep_cleanup
    log_header "TERRAFORM APPLY"
    
    # 1. Aplicar solo catálogos primero para validar imagen
    log_step "Aplicando Catálogos..."
    terraform apply -target=kubernetes_manifest.ibm_operator_catalog -target=kubernetes_manifest.cloud_native_postgres_catalog -auto-approve -no-color >> "$LOG_FILE" 2>&1
    
    # 2. Validar salud antes de seguir
    if ! check_catalogs_health; then
        echo -e "${RED}⚠️  ERROR CRÍTICO: El catálogo de Postgres falló. Revisa el log y corrige catalogs.tf antes de seguir.${NC}"
        exit 1
    fi

    terraform init -no-color >> "$LOG_FILE" 2>&1
    
    log_step "Generando Plan Completo"
    if terraform plan -no-color -out=tfplan 2>&1 | filter_ansi | tee -a "$LOG_FILE"; then
        read -p "❓ ¿Deseas aplicar los cambios con Aprobación Automática? (yes/no): " CONFIRM
        if [[ "$CONFIRM" == "yes" ]]; then
            log_step "Aplicando Configuración"
            terraform apply -no-color "tfplan" 2>&1 | filter_ansi | tee -a "$LOG_FILE"
            log "Esperando propagación del OLM (30s)..."
            sleep 30
            inspect_cluster_state "POST-INSTALL"
        fi
    else
        log "${RED}❌ El plan de Terraform falló. Revisa el log para corregir los errores antes de aplicar.${NC}"
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