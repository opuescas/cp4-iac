#!/usr/bin/env bash

# Directorio de logs organizado
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

# --- LOGGING & VISUALS ---
log_header() {
    echo -e "\n\n================================================================================" >> "$LOG_FILE"
    echo "  $(get_now)  $1" >> "$LOG_FILE"
    echo "================================================================================" >> "$LOG_FILE"
    echo -e "\n${BLUE}>>> $1${NC}"
}
log_step() { echo -e "\n$(get_now) --- $1 ---" | tee -a "$LOG_FILE"; }
log() { echo -e "$(get_now) $1" | tee -a "$LOG_FILE"; }
filter_ansi() { sed -e 's/\x1b\[[0-9;]*[mGJK]//g' -e 's/\x1b\[[0-9;]*[ABCDEFHJKST]//g'; }

# Cuenta regresiva visual
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

# Ejecutar y Verificar (Antes/Despues)
exec_check() {
    local cmd_desc=$1
    local cmd_run=$2
    local cmd_verify=$3
    
    log_step "$cmd_desc"
    
    if [ ! -z "$cmd_verify" ]; then
        echo -e "${CYAN}--- ESTADO PREVIO ---${NC}"
        eval "$cmd_verify" || echo "(Nada encontrado)"
    fi

    echo -e "${GREEN}>>> EJECUTANDO: $cmd_run${NC}"
    eval "$cmd_run" >> "$LOG_FILE" 2>&1

    echo -e "${CYAN}--- ESTADO ACTUAL ---${NC}"
    sleep 2
    if [ ! -z "$cmd_verify" ]; then
        eval "$cmd_verify" || echo "(Recurso eliminado o no encontrado)"
    fi
}

# --- AUTO IMPORT INTELIGENTE ---
safe_import() {
    local TF_ADDR=$1; local IMPORT_ID=$2; local RES_DESC=$3
    if terraform state list | grep -Fq "$TF_ADDR"; then 
        log "ℹ️  $RES_DESC: Ya gestionado por TF (OK)."
    else
        log "🔎 Buscando $RES_DESC en el clúster..."
        if [[ "$TF_ADDR" == *"subscription"* ]] || [[ "$TF_ADDR" == *"manifest"* ]]; then
             terraform import -no-color "$TF_ADDR" "$IMPORT_ID" >> "$LOG_FILE" 2>&1
             if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ $RES_DESC: Existía -> Importado a Terraform.${NC}"
             else
                log "ℹ️  $RES_DESC: No existe. Se creará."
             fi
        else
             terraform import -no-color "$TF_ADDR" "$IMPORT_ID" >> "$LOG_FILE" 2>&1 || true
        fi
    fi
}

sync_existing_resources() {
    log_header "SINCRONIZACIÓN INCREMENTAL"
    # Catálogos
    safe_import "kubernetes_manifest.ibm_operator_catalog" "apiVersion=operators.coreos.com/v1alpha1,kind=CatalogSource,namespace=openshift-marketplace,name=ibm-operator-catalog" "Catálogo IBM"
    safe_import "kubernetes_manifest.opencloud_operators_catalog" "apiVersion=operators.coreos.com/v1alpha1,kind=CatalogSource,namespace=openshift-marketplace,name=opencloud-operators" "Catálogo OpenCloud"
    # Namespaces
    safe_import "kubernetes_namespace.cp4i" "cp4i" "Namespace cp4i"
    safe_import "kubernetes_namespace.ibm_common_services" "ibm-common-services" "Namespace ibm-common-services"
    # Operadores
    safe_import "kubernetes_manifest.cp4i_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=openshift-operators,name=ibm-integration-platform-navigator" "Operador CP4I"
    safe_import "kubernetes_manifest.fs_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=openshift-operators,name=ibm-common-service-operator" "Operador FS"
    safe_import "kubernetes_manifest.mq_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=openshift-operators,name=ibm-mq" "Operador MQ"
    safe_import "kubernetes_manifest.app_connect_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=openshift-operators,name=ibm-appconnect" "Operador AppConnect"
    safe_import "kubernetes_manifest.api_connect_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=openshift-operators,name=ibm-apiconnect" "Operador APIConnect"
    safe_import "kubernetes_manifest.datapower_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=openshift-operators,name=datapower-operator" "Operador DataPower"
    # Instancia
    safe_import "kubernetes_manifest.platform_navigator" "apiVersion=integration.ibm.com/v1beta1,kind=PlatformNavigator,namespace=cp4i,name=integration-quickstart-cdt" "Instancia Platform UI"
}

# --- FUNCIONES DE CURACIÓN ---
post_install_booster() {
    log_step "🚀 Impulso Post-Instalación"
    local NS="openshift-operators"
    local TARGETS=("ibm-appconnect" "ibm-mq" "ibm-apiconnect" "datapower-operator")
    local NEEDS_CATALOG_REFRESH=0
    echo -e "${CYAN}--- VERIFICANDO COMPONENTES ---${NC}"
    for OP in "${TARGETS[@]}"; do
        if oc get subscription "$OP" -n "$NS" >/dev/null 2>&1; then
            local CURRENT_CSV=$(oc get subscription "$OP" -n "$NS" -o jsonpath='{.status.currentCSV}')
            if [ -z "$CURRENT_CSV" ]; then
                echo -e "${RED}⏳ '$OP': OLM lento, sin CSV.${NC}"; NEEDS_CATALOG_REFRESH=1
            else
                local PHASE=$(oc get csv "$CURRENT_CSV" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
                if [ "$PHASE" == "Succeeded" ]; then echo -e "${GREEN}✅ '$OP': Instalado ($CURRENT_CSV)${NC}"
                else echo -e "${YELLOW}🔄 '$OP': Instalando... ($CURRENT_CSV is $PHASE)${NC}"; fi
            fi
        else echo -e "${YELLOW}Wait: '$OP' no encontrado aún.${NC}"; fi
    done
    if [ $NEEDS_CATALOG_REFRESH -eq 1 ]; then
        log_step "Refrescando Catálogo..."
        oc delete pod -n openshift-marketplace -l olm.catalogSource=ibm-operator-catalog --wait=false
        countdown 45 "Esperando reinicio del catálogo"
        log "📝 Aprobando planes..."
        oc get installplan -n $NS --no-headers | grep -v "Complete" | awk '{print $1}' | xargs oc patch installplan -n $NS --type merge -p '{"spec":{"approved":true}}' 2>/dev/null
    fi
}

pre_install_cleaner() {
    log_step "🧹 Chequeo Pre-Instalación"
    local NS="openshift-operators"
    local TARGETS=("ibm-appconnect" "ibm-mq" "ibm-apiconnect" "datapower-operator")
    for OP in "${TARGETS[@]}"; do
        if oc get subscription "$OP" -n "$NS" >/dev/null 2>&1; then
            local CURRENT_CSV=$(oc get subscription "$OP" -n "$NS" -o jsonpath='{.status.currentCSV}')
            if [ -z "$CURRENT_CSV" ]; then
                log "${YELLOW}⚠️  Suscripción '$OP' zombie. Reiniciando...${NC}"
                oc delete subscription "$OP" -n "$NS"
            else
                local PHASE=$(oc get csv "$CURRENT_CSV" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
                if [ "$PHASE" == "Failed" ]; then
                     log "${YELLOW}⚠️  CSV '$CURRENT_CSV' falló. Limpiando...${NC}"
                     oc delete csv "$CURRENT_CSV" -n "$NS" --wait=false
                fi
            fi
        fi
    done
}

# --- FUNCIONES DE LIMPIEZA TOTAL (NUCLEAR) ---
nuke_namespace() {
    local NS=$1
    if oc get namespace $NS >/dev/null 2>&1; then
        log_step "Protocolo Nuclear: $NS"
        oc delete namespace $NS --wait=false --ignore-not-found >/dev/null 2>&1
        oc patch namespace $NS --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
        countdown 3 "Esperando API"
        if oc get namespace $NS >/dev/null 2>&1; then
            log "⚠️  Inyección letal (Raw API)..."
            oc get namespace $NS -o json | \
            python3 -c "import sys, json; d = json.load(sys.stdin); d['spec']['finalizers'] = []; json.dump(d, sys.stdout)" | \
            oc replace --raw "/api/v1/namespaces/$NS/finalize" -f - >/dev/null 2>&1
        fi
    fi
}

deep_clean_manual() {
    log_header "LIMPIEZA MANUAL PROFUNDA (Terraform Bypass)"
    local NS_OPS="openshift-operators"
    
    # 1. Namespaces de aplicación
    nuke_namespace "cp4i"
    nuke_namespace "ibm-common-services"
    
    # 2. OperandRequests
    oc delete operandrequest --all -A --wait=false --grace-period=0 2>/dev/null
    
    # 3. Operadores y CSVs
    log_step "Borrando Operadores en $NS_OPS"
    oc delete subscription --all -n $NS_OPS --ignore-not-found
    oc get csv -n $NS_OPS -o name | grep -E "ibm-|odlm|operand-deployment|datapower|mq|connect" | xargs oc delete -n $NS_OPS --wait=false 2>/dev/null
    
    # 4. Catálogos
    log_step "Borrando Catálogos"
    oc delete catalogsource ibm-operator-catalog opencloud-operators -n openshift-marketplace --ignore-not-found

    # 5. Estado de Terraform (Importante porque TF falló)
    log_step "Purgando estado corrupto de Terraform"
    rm -f terraform.tfstate terraform.tfstate.backup
    echo -e "${GREEN}✅ Archivos .tfstate eliminados para instalación fresca.${NC}"
    
    countdown 5 "Finalizando limpieza"
}

# --- CREDENCIALES ---
get_credentials() {
    local NAMESPACE="ibm-common-services"
    local SECRET_NAME=$(oc get secret -n $NAMESPACE -o name | grep "integration-admin-initial-temporary-credentials" | head -n 1)
    if [ -z "$SECRET_NAME" ]; then echo -e "${RED}❌ No se encontró secreto en '$NAMESPACE'.${NC}"; return; fi
    local PASSWORD=$(oc extract $SECRET_NAME -n $NAMESPACE --to=- --keys=password 2>/dev/null)
    local USER=$(oc extract $SECRET_NAME -n $NAMESPACE --to=- --keys=username 2>/dev/null)
    local URL=$(oc get route -n $NAMESPACE -l integration.ibm.com/kind=PlatformNavigator -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
    [ -z "$URL" ] && URL="(Ruta pendiente...)" || URL="https://$URL"
    echo -e "\n${GREEN}=== ACCESO CP4I ===${NC}\n🔗 URL: $URL\n👤 User: $USER\n🔑 Pass: $PASSWORD\n"
}

# --- MENÚ ---
clear
echo -e "${BLUE}=== GESTOR CP4I (ROBUST) ===${NC}"
echo "1) APLICAR CAMBIOS (Incremental / Reparar)"
echo "2) DESINSTALAR TODO (Fuerza Bruta si TF falla)"
echo "3) OBTENER CREDENCIALES"
read -p "Opción [1-3]: " OPTION

case $OPTION in
  1)
    pre_install_cleaner
    log_header "TERRAFORM INIT"
    terraform init -no-color >> "$LOG_FILE" 2>&1
    sync_existing_resources
    log_step "Generando Plan Incremental"
    if terraform plan -no-color -out=tfplan 2>&1 | filter_ansi | tee -a "$LOG_FILE"; then
        read -p "❓ ¿Aplicar cambios? (yes/no): " CONFIRM
        if [[ "$CONFIRM" == "yes" ]]; then
            echo -e "${GREEN}>>> EJECUTANDO: terraform apply${NC}"
            terraform apply -no-color "tfplan" 2>&1 | filter_ansi | tee -a "$LOG_FILE"
            countdown 10 "Verificando estado"
            if oc get commonservice common-service -n openshift-operators >/dev/null 2>&1; then
                 local ACC=$(oc get commonservice common-service -n openshift-operators -o jsonpath='{.spec.license.accept}')
                 if [ "$ACC" != "true" ]; then
                     echo -e "${GREEN}>>> ACEPTANDO LICENCIA...${NC}"
                     oc patch commonservice common-service -n openshift-operators --type=merge -p '{"spec": {"license": {"accept": true}}}' >> "$LOG_FILE" 2>&1
                 fi
            fi
            post_install_booster
        fi
    else
        log "${RED}❌ Error en Plan.${NC}"
        exit 1
    fi
    ;;
  2)
    echo -e "${RED}⚠️  ESTA ACCIÓN BORRARÁ TODO (MQ, APIC, DATAPOWER, ETC).${NC}"
    echo -e "${YELLOW}Si Terraform falla por timeout, se forzará el borrado manual.${NC}"
    read -p "Escribe 'DESTROY' para confirmar: " CONFIRM
    if [[ "$CONFIRM" == "DESTROY" ]]; then 
        echo -e "${GREEN}>>> INTENTANDO: terraform destroy (Graceful)${NC}"
        # Intentamos terraform primero
        if terraform destroy -auto-approve -no-color 2>&1 | filter_ansi | tee -a "$LOG_FILE"; then
            log "Terraform terminó correctamente. Limpiando residuos..."
            deep_clean_manual
        else
            echo -e "${RED}❌ Terraform falló (Timeout/Plugin Error).${NC}"
            echo -e "${YELLOW}>>> ACTIVANDO MODO FUERZA BRUTA (Borrando recursos y estado)...${NC}"
            deep_clean_manual
        fi
    fi
    ;;
  3) get_credentials ;;
  *) log "Opción inválida." ;;
esac
log_header "FIN"