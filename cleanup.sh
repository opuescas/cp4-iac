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

# NUEVA FUNCIÓN: Automatiza la corrección de ODLM que hiciste manualmente
purge_conflicting_odlm() {
    log_step "🧹 Limpieza preventiva de conflictos ODLM (Anti-Deadlock)"
    
    # 1. Identificar CSVs de ODLM (viejos o rotos) en openshift-operators
    # Esto borra específicamente la v4.3.17 o cualquiera que esté en estado zombie
    local zombies=$(oc get csv -n openshift-operators -o name | grep -E "operand-deployment-lifecycle-manager|ibm-odlm")
    
    if [ ! -z "$zombies" ]; then
        log "⚠️  Detectados rastros de ODLM que podrían causar conflictos. Eliminando..."
        echo "$zombies" | xargs oc delete -n openshift-operators --wait=false 2>/dev/null
        
        # 2. Eliminar suscripciones huérfanas de ODLM y Postgres para forzar reinstalación limpia
        log "Reiniciando suscripciones críticas (ODLM y Postgres)..."
        oc delete subscription ibm-odlm operand-deployment-lifecycle-manager-app cloud-native-postgresql -n openshift-operators --ignore-not-found
        
        log "✅ Zona ODLM limpia. El operador principal instalará las versiones correctas."
    else
        log "✅ No se encontraron conflictos obvios de ODLM."
    fi
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
    # Llama a la función especializada
    purge_conflicting_odlm
    
    # Limpieza general extra
    oc delete subscription --all -n openshift-operators | grep ibm >> "$LOG_FILE" 2>&1 || true

    log_step "Borrando Namespaces de Aplicación"
    oc delete namespace cp4i ibm-common-services --grace-period=0 --force --wait=false 2>/dev/null
    
    log "Esperando estabilización del API (10s)..."
    sleep 10
}

# --- FUNCIÓN INTELIGENTE: AUTO IMPORTAR ---
auto_import_catalogs() {
    log_step "Verificando catálogos existentes para importar al estado..."

    if oc get catalogsource ibm-operator-catalog -n openshift-marketplace >/dev/null 2>&1; then
        log "ℹ️  'ibm-operator-catalog' ya existe. Importando a Terraform..."
        terraform import -no-color kubernetes_manifest.ibm_operator_catalog "apiVersion=operators.coreos.com/v1alpha1,kind=CatalogSource,namespace=openshift-marketplace,name=ibm-operator-catalog" >> "$LOG_FILE" 2>&1 || true
    fi

    if oc get catalogsource opencloud-operators -n openshift-marketplace >/dev/null 2>&1; then
        log "ℹ️  'opencloud-operators' ya existe. Importando a Terraform..."
        terraform import -no-color kubernetes_manifest.opencloud_operators_catalog "apiVersion=operators.coreos.com/v1alpha1,kind=CatalogSource,namespace=openshift-marketplace,name=opencloud-operators" >> "$LOG_FILE" 2>&1 || true
    fi
}

# --- FUNCIÓN NUEVA: OBTENER CREDENCIALES ---
get_credentials() {
    log_header "OBTENCIÓN DE CREDENCIALES PLATFORM UI"
    local NAMESPACE="ibm-common-services"
    
    # Busca el secreto buscando el patrón, ya que el nombre exacto puede variar según el CR
    local SECRET_NAME=$(oc get secret -n $NAMESPACE -o name | grep "integration-admin-initial-temporary-credentials" | head -n 1)
    
    if [ -z "$SECRET_NAME" ]; then
        echo -e "${RED}❌ No se encontró el secreto de contraseña temporal en el namespace '$NAMESPACE'.${NC}"
        echo -e "   Posibles causas:"
        echo -e "   1. La instalación aún no ha terminado (puede tardar 15-40 min)."
        echo -e "   2. El PlatformNavigator falló al instalarse."
        return
    fi

    # Extraer contraseña y URL
    log "Extrayendo credenciales de $SECRET_NAME..."
    local PASSWORD=$(oc extract $SECRET_NAME -n $NAMESPACE --to=- --keys=password 2>/dev/null)
    local USER=$(oc extract $SECRET_NAME -n $NAMESPACE --to=- --keys=username 2>/dev/null)
    local URL=$(oc get route -n $NAMESPACE -l integration.ibm.com/kind=PlatformNavigator -o jsonpath='{.items[0].spec.host}' 2>/dev/null)

    if [ -z "$URL" ]; then
         URL="(Ruta aún no disponible, revisa 'oc get routes -n cp4i')"
    else
         URL="https://$URL"
    fi

    echo -e "\n${GREEN}==========================================================${NC}"
    echo -e "${GREEN}      ACCESO A IBM CLOUD PAK FOR INTEGRATION (CP4I)      ${NC}"
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "🔗 URL:      $URL"
    echo -e "👤 Usuario:  $USER"
    echo -e "🔑 Password: $PASSWORD"
    echo -e "${GREEN}==========================================================${NC}\n"
    
    # Guardar en log también (opcional, cuidado con seguridad)
    echo "Credenciales mostradas en pantalla para admin." >> "$LOG_FILE"
}

# --- MENÚ PRINCIPAL ---
clear
echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}        IBM CP4I - GESTOR DE CICLO DE VIDA         ${NC}"
echo -e "${BLUE}====================================================${NC}"
echo "Directorio de logs: $LOG_DIR"
echo "Log actual: $LOG_FILE"
echo "----------------------------------------------------"
echo "1) INSTALACIÓN INTELIGENTE (Purga Conflictos + Apply)"
echo "2) DESINSTALACIÓN / DESTRABAR (Destroy + Finalizers)"
echo "3) SOLO LIMPIEZA MANUAL (Rescate rápido)"
echo "4) OBTENER CREDENCIALES Y URL (Platform UI)"
echo "----------------------------------------------------"
read -p "Selecciona una opción [1-4]: " OPTION

case $OPTION in
  1)
    run_deep_cleanup
    # Aseguramos purga específica ODLM después de la limpieza general
    purge_conflicting_odlm
    
    log_header "TERRAFORM INIT"
    terraform init -no-color >> "$LOG_FILE" 2>&1
    
    auto_import_catalogs
    
    log_step "Generando Plan"
    if terraform plan -no-color -out=tfplan 2>&1 | filter_ansi | tee -a "$LOG_FILE"; then
        echo ""
        read -p "❓ ¿Deseas aplicar los cambios? (yes/no): " CONFIRM
        if [[ "$CONFIRM" == "yes" ]]; then
            log_step "Aplicando Configuración"
            terraform apply -no-color "tfplan" 2>&1 | filter_ansi | tee -a "$LOG_FILE"
            
            log_step "Post-Instalación: Verificando Licencia CommonServices"
            log "Esperando 15s para que el operador cree el CR..."
            sleep 15
            # Intento de auto-aceptación de licencia para evitar estado Failed
            if oc get commonservice common-service -n openshift-operators >/dev/null 2>&1; then
                 oc patch commonservice common-service -n openshift-operators --type=merge -p '{"spec": {"license": {"accept": true}}}' >> "$LOG_FILE" 2>&1
                 log "✅ Licencia aceptada automáticamente."
            else
                 log "ℹ️ CommonService aún no creado por el operador. Terraform terminará y el operador lo creará pronto."
            fi

            log "Instalación en curso. Espera unos 15-20 minutos para que aparezca la UI."
            inspect_cluster_state "POST-INSTALL"
        fi
    else
        log "${RED}❌ El plan de Terraform falló. Revisa el log.${NC}"
        exit 1
    fi
    ;;
  2)
    inspect_cluster_state "PRE-DESTROY"
    log_header "FASE: TERRAFORM DESTROY"
    read -p "⚠️ ¿Seguro que deseas DESTRUIR todo? (yes/no): " CONFIRM
    if [[ "$CONFIRM" == "yes" ]]; then
        log_step "Iniciando Destroy..."
        terraform destroy -auto-approve -no-color 2>&1 | filter_ansi | tee -a "$LOG_FILE" &
        TF_PID=$!
        count=0
        while kill -0 $TF_PID 2>/dev/null && [ $count -lt 36 ]; do
            echo -n "."; sleep 5
            ((count++))
        done
        if kill -0 $TF_PID 2>/dev/null; then kill -9 $TF_PID 2>/dev/null; fi
        run_deep_cleanup
        log_step "Desinstalación completada."
    fi
    ;;
  3)
    run_deep_cleanup
    inspect_cluster_state "CLEANUP-DONE"
    ;;
  4)
    get_credentials
    ;;
  *)
    log "Opción inválida."
    ;;
esac

log_header "FIN DE LA SESIÓN"