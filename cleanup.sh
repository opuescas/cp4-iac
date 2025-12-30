#!/usr/bin/env bash

# Directorio de logs
LOG_DIR="logs"
mkdir -p "$LOG_DIR"
TIMESTAMP_FILE=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${LOG_DIR}/cp4i_execution_${TIMESTAMP_FILE}.log"

# Colores
BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

get_now() { date +"[%Y-%m-%d %H:%M:%S]"; }

# --- UTILS ---
log_header() {
    echo -e "\n\n================================================================================" >> "$LOG_FILE"
    echo "  $(get_now)  $1" >> "$LOG_FILE"
    echo "================================================================================" >> "$LOG_FILE"
    echo -e "\n${BLUE}>>> $1${NC}"
}
log_step() { echo -e "\n$(get_now) --- $1 ---" | tee -a "$LOG_FILE"; }
log() { echo -e "$(get_now) $1" | tee -a "$LOG_FILE"; }
filter_ansi() { sed -e 's/\x1b\[[0-9;]*[mGJK]//g' -e 's/\x1b\[[0-9;]*[ABCDEFHJKST]//g'; }

countdown() {
    local secs=$1
    local msg=$2
    echo -ne "${YELLOW}$msg: $secs${NC}"
    while [ $secs -gt 0 ]; do
        echo -ne "\r${YELLOW}$msg: $secs s...   ${NC}"
        sleep 1
        : $((secs--))
    done
    echo -e "\r${GREEN}$msg: Listo.        ${NC}"
}

# --- VALIDACIÓN Y ACCESO ---

validate_and_reveal_access() {
    log_header "VALIDACIÓN DE ESTADO Y ACCESO"
    local NS="cp4i"
    local OPS_NS="ibm-common-services"
    
    # 1. Tabla de Estado de Componentes
    echo -e "${CYAN}--- ESTADO DE COMPONENTES EN $NS ---${NC}"
    
    oc get platformnavigator,apiconnectcluster,dashboard,queuemanager,datapowerservice -n $NS \
       -o "custom-columns=KIND:.kind,NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,MESSAGE:.status.conditions[?(@.type=='Ready')].message" \
       --sort-by=.kind 2>/dev/null || echo "ℹ️  Aún no se detectan instancias desplegadas."
    
    # 2. Validación de Platform Navigator
    log_step "Verificando disponibilidad de Platform UI"
    local NAV_NAME=$(oc get platformnavigator -n $NS -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$NAV_NAME" ]; then
        echo -e "${RED}❌ No se encontró instancia de PlatformNavigator en $NS.${NC}"
        # Intentamos mostrar si Cert Manager está vivo en el namespace CORRECTO
        echo -e "${YELLOW}Check Cert-Manager:${NC}"
        oc get csv -n cert-manager-operator -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null || echo "Namespace cert-manager-operator no encontrado."
        return
    fi

    local READY="False"
    local ATTEMPTS=0
    while [ "$READY" != "True" ] && [ $ATTEMPTS -lt 12 ]; do
        READY=$(oc get platformnavigator $NAV_NAME -n $NS -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "$READY" == "True" ]; then break; fi
        echo -e "${YELLOW}⏳ Platform UI no está lista aún. Esperando 10s... (Intento $ATTEMPTS/12)${NC}"
        sleep 10
        ((ATTEMPTS++))
    done

    if [ "$READY" == "True" ]; then
        # 3. Extracción de Credenciales y URL
        local SECRET_NAME=$(oc get secret -n $OPS_NS -o name | grep "integration-admin-initial-temporary-credentials" | head -n 1)
        
        if [ ! -z "$SECRET_NAME" ]; then
            local PASS=$(oc extract $SECRET_NAME -n $OPS_NS --to=- --keys=password 2>/dev/null)
            local USER=$(oc extract $SECRET_NAME -n $OPS_NS --to=- --keys=username 2>/dev/null)
            local URL=$(oc get route -n $OPS_NS -l integration.ibm.com/kind=PlatformNavigator -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
            
            echo -e "\n${GREEN}======================================================${NC}"
            echo -e "${GREEN}✅   IBM CLOUD PAK FOR INTEGRATION - ACCESO CONCEDIDO  ${NC}"
            echo -e "${GREEN}======================================================${NC}"
            echo -e "🔗 URL:      https://$URL"
            echo -e "👤 Usuario:  $USER"
            echo -e "🔑 Password: $PASS"
            echo -e "${GREEN}======================================================${NC}"
            echo -e "${CYAN}Nota: Cert-Manager y MQ QueueManager deberían estar instalándose en background.${NC}\n"
        else
            echo -e "${RED}❌ Platform UI está Ready, pero no encuentro el secreto de credenciales.${NC}"
        fi
    else
        echo -e "${RED}⚠️  Platform UI tardó demasiado en iniciar.${NC}"
    fi
}

# --- IMPORTACIÓN INTELIGENTE ---
safe_import() {
    local TF_ADDR=$1; local IMPORT_ID=$2; local RES_DESC=$3
    if terraform state list | grep -Fq "$TF_ADDR"; then 
        log "ℹ️  $RES_DESC: Ya gestionado (OK)."
    else
        log "🔎 Buscando $RES_DESC..."
        if [[ "$TF_ADDR" == *"subscription"* ]] || [[ "$TF_ADDR" == *"manifest"* ]]; then
             terraform import -no-color "$TF_ADDR" "$IMPORT_ID" >> "$LOG_FILE" 2>&1
             if [ $? -eq 0 ]; then echo -e "${GREEN}✅ $RES_DESC: Importado.${NC}"; else log "ℹ️  $RES_DESC: Se creará."; fi
        else
             # Para namespaces y configmaps
             terraform import -no-color "$TF_ADDR" "$IMPORT_ID" >> "$LOG_FILE" 2>&1 || true
        fi
    fi
}

sync_existing_resources() {
    log_header "SINCRONIZACIÓN (Importando lo existente)"
    
    # 0. Cert Manager (Namespace CORRECTO: cert-manager-operator)
    safe_import "kubernetes_namespace.cert_manager_ns" "cert-manager-operator" "NS Cert Manager"
    safe_import "kubernetes_manifest.cert_manager_sub" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=cert-manager-operator,name=openshift-cert-manager-operator" "Operador Cert Manager"

    # 1. Namespaces y Catálogos
    safe_import "kubernetes_manifest.ibm_operator_catalog" "apiVersion=operators.coreos.com/v1alpha1,kind=CatalogSource,namespace=openshift-marketplace,name=ibm-operator-catalog" "Catálogo IBM"
    safe_import "kubernetes_namespace.cp4i" "cp4i" "NS cp4i"
    safe_import "kubernetes_namespace.ibm_common_services" "ibm-common-services" "NS ibm-common-services"
    
    # 2. Operadores CP4I
    local NS_OP="openshift-operators"
    safe_import "kubernetes_manifest.cp4i_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=$NS_OP,name=ibm-integration-platform-navigator" "Operador CP4I"
    safe_import "kubernetes_manifest.fs_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=$NS_OP,name=ibm-common-service-operator" "Operador FS"
    safe_import "kubernetes_manifest.mq_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=$NS_OP,name=ibm-mq" "Operador MQ"
    safe_import "kubernetes_manifest.app_connect_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=$NS_OP,name=ibm-appconnect" "Operador AppConnect"
    safe_import "kubernetes_manifest.api_connect_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=$NS_OP,name=ibm-apiconnect" "Operador APIConnect"
    
    # 3. Instancias y ConfigMaps
    safe_import "kubernetes_manifest.platform_navigator" "apiVersion=integration.ibm.com/v1beta1,kind=PlatformNavigator,namespace=cp4i,name=integration-quickstart-cdt" "Instancia Platform UI"
    safe_import "kubernetes_config_map.mqwebuserconfigmap" "cp4i/mqwebuserconfigmap" "ConfigMap MQ Web"
    safe_import "kubernetes_manifest.qm1_cdt" "apiVersion=mq.ibm.com/v1beta1,kind=QueueManager,namespace=cp4i,name=qm1-cdt" "QueueManager QM1"
    safe_import "kubernetes_manifest.apic_cluster" "apiVersion=apiconnect.ibm.com/v1beta1,kind=APIConnectCluster,namespace=cp4i,name=large-cdt" "Instancia API Connect"
}

# --- CURACIÓN ---
post_install_booster() {
    log_step "🚀 Impulso Post-Instalación"
    local NS="openshift-operators"
    local TARGETS=("ibm-appconnect" "ibm-mq" "ibm-apiconnect")
    local NEEDS_REFRESH=0
    
    for OP in "${TARGETS[@]}"; do
        if oc get subscription "$OP" -n "$NS" >/dev/null 2>&1; then
            local CSV=$(oc get subscription "$OP" -n "$NS" -o jsonpath='{.status.currentCSV}')
            if [ -z "$CSV" ]; then NEEDS_REFRESH=1; echo -e "${YELLOW}Wait: $OP sin CSV.${NC}"; 
            else echo -e "${GREEN}OK: $OP ($CSV)${NC}"; fi
        fi
    done

    if [ $NEEDS_REFRESH -eq 1 ]; then
        log_step "Refrescando OLM..."
        oc delete pod -n openshift-marketplace -l olm.catalogSource=ibm-operator-catalog --wait=false
        countdown 30 "Reiniciando catálogo"
        oc get installplan -n $NS --no-headers | grep -v "Complete" | awk '{print $1}' | xargs oc patch installplan -n $NS --type merge -p '{"spec":{"approved":true}}' 2>/dev/null
    fi
}

pre_install_cleaner() {
    local NS="openshift-operators"
    local TARGETS=("ibm-appconnect" "ibm-mq" "ibm-apiconnect")
    for OP in "${TARGETS[@]}"; do
        if oc get subscription "$OP" -n "$NS" >/dev/null 2>&1; then
            local CSV=$(oc get subscription "$OP" -n "$NS" -o jsonpath='{.status.currentCSV}')
            # Solo borramos si es Zombie (sin CSV)
            if [ -z "$CSV" ]; then oc delete subscription "$OP" -n "$NS"; fi
        fi
    done
}

deep_clean_post_destroy() {
    local NS_OPS="openshift-operators"
    if oc get commonservice common-service -n $NS_OPS >/dev/null 2>&1; then
        oc delete commonservice common-service -n $NS_OPS --wait=false --ignore-not-found
        oc patch commonservice common-service -n $NS_OPS --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null
    fi
    oc delete operandrequest --all -A --wait=false --grace-period=0 2>/dev/null
    oc get csv -n $NS_OPS -o name | grep -E "ibm-|odlm|operand-deployment|datapower" | xargs oc delete -n $NS_OPS --wait=false 2>/dev/null
    oc delete subscription --all -n $NS_OPS --ignore-not-found
    
    # Limpieza Cert Manager (Namespace Correcto)
    oc delete namespace cert-manager-operator --wait=false --ignore-not-found
}

# --- MENÚ ---
clear
echo -e "${BLUE}=== GESTOR CP4I (CERT-MANAGER FIXED + MQ + APIC) ===${NC}"
echo "1) APLICAR CAMBIOS (Instalar/Reparar + Obtener Acceso)"
echo "2) DESINSTALAR TODO"
echo "3) SOLO VALIDAR Y OBTENER ACCESO"
read -p "Opción [1-3]: " OPTION

case $OPTION in
  1)
    pre_install_cleaner
    terraform init -no-color >> "$LOG_FILE" 2>&1
    sync_existing_resources
    
    log_step "Generando Plan"
    if terraform plan -no-color -out=tfplan 2>&1 | filter_ansi | tee -a "$LOG_FILE"; then
        read -p "❓ ¿Aplicar cambios? (yes/no): " CONFIRM
        if [[ "$CONFIRM" == "yes" ]]; then
            terraform apply -no-color "tfplan" 2>&1 | filter_ansi | tee -a "$LOG_FILE"
            
            # Post-procesamiento
            if oc get commonservice common-service -n openshift-operators >/dev/null 2>&1; then
                 local ACC=$(oc get commonservice common-service -n openshift-operators -o jsonpath='{.spec.license.accept}')
                 if [ "$ACC" != "true" ]; then
                     oc patch commonservice common-service -n openshift-operators --type=merge -p '{"spec": {"license": {"accept": true}}}' >> "$LOG_FILE" 2>&1
                 fi
            fi
            post_install_booster
            validate_and_reveal_access
        fi
    else
        log "${RED}❌ Error en Plan.${NC}"
        exit 1
    fi
    ;;
  2)
    echo -e "${RED}⚠️  ESTA ACCIÓN BORRARÁ TODO.${NC}"
    read -p "Escribe 'DESTROY' para confirmar: " CONFIRM
    if [[ "$CONFIRM" == "DESTROY" ]]; then 
        if terraform destroy -auto-approve -no-color 2>&1 | filter_ansi | tee -a "$LOG_FILE"; then
            deep_clean_post_destroy
        else
            echo -e "${YELLOW}Terraform falló. Forzando limpieza manual...${NC}"
            deep_clean_post_destroy
            rm -f terraform.tfstate terraform.tfstate.backup
        fi
        log "Infraestructura eliminada."
    fi
    ;;
  3) validate_and_reveal_access ;;
  *) log "Opción inválida." ;;
esac
log_header "FIN"