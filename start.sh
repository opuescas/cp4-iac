#!/usr/bin/env bash

# Asegurar que las rutas comunes de binarios en macOS estén en el PATH
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/ogpuescas/Downloads:$PATH"


# Directorio de logs
LOG_DIR="$(pwd)/logs"
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

# Sincronizar KUBECONFIG con Terraform
if [ ! -z "$KUBECONFIG" ]; then
    export TF_VAR_kube_config_path="$KUBECONFIG"
    echo -e "${YELLOW}ℹ️  Detectado KUBECONFIG personalizado: $KUBECONFIG${NC}"
    echo -e "${YELLOW}ℹ️  Terraform usará esta configuración.${NC}"
fi

# --- VALIDACIÓN DE DEPENDENCIAS ---
echo -e "${BLUE}🔍 Verificando dependencias...${NC}"

# Validar Terraform
if ! command -v terraform &> /dev/null; then
    echo -e "${RED}❌ Error: Terraform no está instalado en el sistema.${NC}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo -e "${YELLOW}👉 Para macOS usa: 'brew install terraform'${NC}"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo -e "${YELLOW}👉 Para Linux usa: 'sudo apt-get install terraform' o equivalente.${NC}"
    elif [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "cygwin"* || "$OSTYPE" == "win32"* ]]; then
        echo -e "${YELLOW}👉 Para Windows usa: 'choco install terraform' o descarga el exe de terraform.io${NC}"
    else
        echo -e "${YELLOW}👉 Visita: https://www.terraform.io/downloads${NC}"
    fi
    exit 1
else
    TF_VER=$(terraform version | head -n 1)
    echo -e "${GREEN}✅ $TF_VER detectado.${NC}"
fi

# Validar OpenShift CLI (oc) - Opcional pero recomendado dado el uso extensivo
if ! command -v oc &> /dev/null; then
    echo -e "${YELLOW}⚠️  Advertencia: 'oc' (OpenShift CLI) no detectado. Algunos diagnósticos fallarán.${NC}"
fi

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

# --- DIAGNÓSTICO Y DESBLOQUEO (SELECTOR CORREGIDO) ---
unblock_stuck_operator() {
    log_step "🔨 Diagnóstico de Bloqueos"
    local NS="cp4i"
    local NS_OP="openshift-operators"

    # 1. VERIFICAR POR QUÉ ESTÁ EN FALSE
    local APIC_STATUS=$(oc get apiconnectcluster -n $NS -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
    
    if [ ! -z "$APIC_STATUS" ]; then
        echo -e "${YELLOW}Estado actual APIC: $APIC_STATUS${NC}"
    fi

    # 2. REINICIO TÁCTICO DEL OPERADOR
    local CM_NGINX=$(oc get cm -n $NS -o name | grep "mgmt-ui-nginx")
    
    if [ -z "$CM_NGINX" ]; then
        echo -e "${RED}⚠️  La instalación está atascada al inicio (Faltan ConfigMaps).${NC}"
        echo -e "${YELLOW}>>> Reiniciando Operador 'ibm-apiconnect' para forzar reconciliación...${NC}"
        
        # BUSQUEDA DE POD CORREGIDA: Busca cualquier pod que empiece con 'ibm-apiconnect-'
        local OP_POD=$(oc get pods -n $NS_OP -o name | grep "^pod/ibm-apiconnect-" | head -n 1)
        
        if [ ! -z "$OP_POD" ]; then
            echo -e "${GREEN}♻️  Pod encontrado: $OP_POD. Reiniciando...${NC}"
            oc delete $OP_POD -n $NS_OP --wait=false
            countdown 25 "Esperando reinicio del operador"
        else
            # Fallback: Intenta buscar sin el prefijo pod/
            OP_POD=$(oc get pods -n $NS_OP --no-headers | grep "^ibm-apiconnect-" | awk '{print $1}' | head -n 1)
            if [ ! -z "$OP_POD" ]; then
                echo -e "${GREEN}♻️  Pod encontrado (Fallback): $OP_POD. Reiniciando...${NC}"
                oc delete pod $OP_POD -n $NS_OP --wait=false
                countdown 25 "Esperando reinicio del operador"
            else
                echo -e "${RED}❌ ERROR CRÍTICO: No se pudo encontrar el pod del operador APIC en $NS_OP.${NC}"
            fi
        fi
    else
        echo -e "${GREEN}✅ El proceso ha avanzado (ConfigMaps creados). Pasando a verificación de Hotfix.${NC}"
    fi
}

# --- HOTFIX NGINX (CONDICIONAL) ---
apply_nginx_hotfix() {
    log_step "🛡️  Verificación de Integridad: NGINX Config"
    local NS="cp4i"
    local CM_NAME=$(oc get cm -n $NS -o name | grep "mgmt-ui-nginx" | head -n 1 | cut -d/ -f2)
    
    if [ -z "$CM_NAME" ]; then
        echo "ℹ️  ConfigMap de NGINX aún no existe (Esperando al operador...)."
        return
    fi

    oc get cm $CM_NAME -n $NS -o yaml > nginx_check.yaml
    
    if grep -q "window.apiConnectCfg = \$api_connect_cfg</script>'" nginx_check.yaml; then
        if ! grep -q "window.apiConnectCfg = \$api_connect_cfg</script>';" nginx_check.yaml; then
            echo -e "${RED}⚠️  DETECTADO BUG DE SINTAXIS (Falta ';') EN V12.1${NC}"
            echo -e "${YELLOW}>>> Aplicando parche correctivo...${NC}"
            sed -i "s|window.apiConnectCfg = \$api_connect_cfg</script>'|window.apiConnectCfg = \$api_connect_cfg</script>';|g" nginx_check.yaml
            oc apply -f nginx_check.yaml -n $NS
            echo -e "${YELLOW}>>> Reiniciando Pod UI para activar el fix...${NC}"
            oc delete pod -n $NS -l app.kubernetes.io/component=management-ui --wait=false
            echo -e "${GREEN}✅ Parche aplicado.${NC}"
        else
            echo -e "${GREEN}✅ La configuración de NGINX es correcta.${NC}"
        fi
    else
        echo -e "${GREEN}✅ No se detectó la línea problemática.${NC}"
    fi
    rm -f nginx_check.yaml
}

# --- VALIDACIÓN Y ACCESO ---
validate_and_reveal_access() {
    log_header "VALIDACIÓN DE ESTADO Y ACCESO"
    local NS="cp4i"
    local OPS_NS="ibm-common-services"
    local CM_NS="cert-manager-operator"

    echo -e "${CYAN}--- ESTADO DE PREREQUISITOS (CertManager) ---${NC}"
    if oc get namespace $CM_NS >/dev/null 2>&1; then
        echo -e "${YELLOW}Operador:${NC}"
        oc get csv -n $CM_NS -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,DISPLAY:.spec.displayName
        echo -e "${YELLOW}Instancia 'Cluster':${NC}"
        if oc get certmanager cluster >/dev/null 2>&1; then
             oc get certmanager cluster -o "custom-columns=NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Available')].status"
        else
             echo "⚠️  Instancia 'CertManager/cluster' no encontrada (Puede estar inicializando)."
        fi
    else
        echo -e "${RED}❌ Namespace '$CM_NS' no encontrado. CertManager no está instalado.${NC}"
    fi
    echo ""

    echo -e "${CYAN}--- ESTADO DE COMPONENTES EN $NS ---${NC}"
    oc get platformnavigator,apiconnectcluster,dashboard,queuemanager,datapowerservice -n $NS \
       -o "custom-columns=KIND:.kind,NAME:.metadata.name,VERSION:.spec.version,STATUS:.status.conditions[?(@.type=='Ready')].status,MESSAGE:.status.conditions[?(@.type=='Ready')].message" \
       --sort-by=.kind 2>/dev/null || echo "ℹ️  Aún no se detectan instancias desplegadas."
    
    local NAV_NAME=$(oc get platformnavigator -n $NS -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ ! -z "$NAV_NAME" ]; then
        local READY=$(oc get platformnavigator $NAV_NAME -n $NS -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "$READY" == "True" ]; then
            local SECRET_NAME=$(oc get secret -n $OPS_NS -o name | grep "integration-admin-initial-temporary-credentials" | head -n 1)
            if [ ! -z "$SECRET_NAME" ]; then
                local PASS=$(oc extract $SECRET_NAME -n $OPS_NS --to=- --keys=password 2>/dev/null)
                local USER=$(oc extract $SECRET_NAME -n $OPS_NS --to=- --keys=username 2>/dev/null)
                local URL=$(oc get route -n $NS -l integration.ibm.com/kind=PlatformNavigator -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
                if [ -z "$URL" ]; then URL=$(oc get route -n $OPS_NS -l integration.ibm.com/kind=PlatformNavigator -o jsonpath='{.items[0].spec.host}' 2>/dev/null); fi
                
                echo -e "\n${GREEN}======================================================${NC}"
                echo -e "${GREEN}✅   IBM CLOUD PAK FOR INTEGRATION - ACCESO CONCEDIDO  ${NC}"
                echo -e "${GREEN}======================================================${NC}"
                echo -e "🔗 URL:      https://$URL"
                echo -e "👤 Usuario:  $USER"
                echo -e "🔑 Password: $PASS"
                echo -e "${GREEN}======================================================${NC}\n"
            fi
        fi
    fi
}

# --- IMPORTACIÓN INTELIGENTE ---
safe_import() {
    local TF_ADDR=$1; local IMPORT_ID=$2; local RES_DESC=$3
    if terraform state list | grep -Fq "$TF_ADDR"; then log "ℹ️  $RES_DESC: Ya gestionado (OK)."; else
        log "🔎 Buscando $RES_DESC..."
        if [[ "$TF_ADDR" == *"subscription"* ]] || [[ "$TF_ADDR" == *"manifest"* ]]; then
             terraform import -no-color "$TF_ADDR" "$IMPORT_ID" >> "$LOG_FILE" 2>&1
             if [ $? -eq 0 ]; then echo -e "${GREEN}✅ $RES_DESC: Importado.${NC}"; else log "ℹ️  $RES_DESC: Se creará."; fi
        else
             terraform import -no-color "$TF_ADDR" "$IMPORT_ID" >> "$LOG_FILE" 2>&1 || true
        fi
    fi
}

sync_existing_resources() {
    log_header "SINCRONIZACIÓN"
    safe_import "kubernetes_namespace.cert_manager_ns" "cert-manager-operator" "NS Cert Manager"
    safe_import "kubernetes_manifest.cert_manager_sub" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=cert-manager-operator,name=openshift-cert-manager-operator" "Operador Cert Manager"

    
    safe_import "kubernetes_manifest.ibm_operator_catalog" "apiVersion=operators.coreos.com/v1alpha1,kind=CatalogSource,namespace=openshift-marketplace,name=ibm-operator-catalog" "Catálogo IBM"
    safe_import "kubernetes_namespace.cp4i" "cp4i" "NS cp4i"
    safe_import "kubernetes_namespace.ibm_common_services" "ibm-common-services" "NS ibm-common-services"
    
    local NS_OP="openshift-operators"
    safe_import "kubernetes_manifest.cp4i_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=$NS_OP,name=ibm-integration-platform-navigator" "Operador CP4I"
    safe_import "kubernetes_manifest.fs_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=$NS_OP,name=ibm-common-service-operator" "Operador FS"
    safe_import "kubernetes_manifest.mq_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=$NS_OP,name=ibm-mq" "Operador MQ"
    safe_import "kubernetes_manifest.app_connect_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=$NS_OP,name=ibm-appconnect" "Operador AppConnect"
    safe_import "kubernetes_manifest.api_connect_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=$NS_OP,name=ibm-apiconnect" "Operador APIConnect"
    safe_import "kubernetes_manifest.datapower_operator" "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=$NS_OP,name=datapower-operator" "Operador DataPower"
    
    safe_import "kubernetes_manifest.platform_navigator" "apiVersion=integration.ibm.com/v1beta1,kind=PlatformNavigator,namespace=cp4i,name=integration-quickstart-cdt" "Instancia Platform UI"
    safe_import "kubernetes_config_map.mqwebuserconfigmap" "cp4i/mqwebuserconfigmap" "ConfigMap MQ Web"
    safe_import "kubernetes_manifest.qm1_cdt" "apiVersion=mq.ibm.com/v1beta1,kind=QueueManager,namespace=cp4i,name=qm1-cdt" "QueueManager QM1"
    
    local APIC_VER=$(oc get apiconnectcluster -n cp4i -o jsonpath='{.items[0].spec.version}' 2>/dev/null)
    local APIC_NAME=$(oc get apiconnectcluster -n cp4i -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ ! -z "$APIC_NAME" ]; then
        safe_import "kubernetes_manifest.apic_cluster" "apiVersion=apiconnect.ibm.com/v1beta1,kind=APIConnectCluster,namespace=cp4i,name=$APIC_NAME" "Instancia API Connect"
    fi

    # Automatizados de DataPower
    safe_import "kubernetes_manifest.gen_DP_configmap" "apiVersion=v1,kind=ConfigMap,namespace=cp4i-idg,name=dp-web-mgmt" "DataPower ConfigMap (Auto)"
    safe_import "kubernetes_manifest.gen_DP_route" "apiVersion=route.openshift.io/v1,kind=Route,namespace=cp4i-idg,name=dp-webui" "DataPower Route (Auto)"
    safe_import "kubernetes_manifest.gen_DP_service" "apiVersion=v1,kind=Service,namespace=cp4i-idg,name=dp-mgmt-svc" "DataPower Service (Auto)"
    safe_import "kubernetes_manifest.gen_DP_cdt_dp_service" "apiVersion=datapower.ibm.com/v1beta3,kind=DataPowerService,namespace=cp4i-idg,name=cdt-dp-service" "DataPower Instance (Auto)"
    
    # Automatizado Dashboard
    safe_import "kubernetes_manifest.gen_ACE_int_dashboard" "apiVersion=appconnect.ibm.com/v1beta1,kind=Dashboard,namespace=cp4i,name=dshb-cdt" "Dashboard AppConnect (Auto)"
}

post_install_booster() {
    log_step "🚀 Impulso Post-Instalación"
    local NS="openshift-operators"
    local NEEDS_REFRESH=0
    for OP in "ibm-appconnect" "ibm-mq" "ibm-apiconnect"; do
        if oc get subscription "$OP" -n "$NS" >/dev/null 2>&1; then
            local CSV=$(oc get subscription "$OP" -n "$NS" -o jsonpath='{.status.currentCSV}')
            if [ -z "$CSV" ]; then NEEDS_REFRESH=1; fi
        fi
    done
    if [ $NEEDS_REFRESH -eq 1 ]; then
        oc delete pod -n openshift-marketplace -l olm.catalogSource=ibm-operator-catalog --wait=false
        oc get installplan -n $NS --no-headers | grep -v "Complete" | awk '{print $1}' | xargs oc patch installplan -n $NS --type merge -p '{"spec":{"approved":true}}' 2>/dev/null
    fi
}

pre_install_cleaner() {
    local NS="openshift-operators"
    local TARGETS=("ibm-appconnect" "ibm-mq" "ibm-apiconnect")
    for OP in "${TARGETS[@]}"; do
        if oc get subscription "$OP" -n "$NS" >/dev/null 2>&1; then
            local CSV=$(oc get subscription "$OP" -n "$NS" -o jsonpath='{.status.currentCSV}')
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
    oc delete namespace cert-manager-operator --wait=false --ignore-not-found
}

# --- MENÚ ---
clear
echo -e "${BLUE}=== GESTOR CP4I (POD FINDER FIX) ===${NC}"
echo "1) APLICAR (Install + Auto-Unblock + Hotfix)"
echo "2) DESINSTALAR TODO"
echo "3) SOLO VALIDAR Y OBTENER ACCESO"
read -p "Opción [1-3]: " OPTION

case $OPTION in
  1)
    ./scripts/yaml_to_tf.sh
    pre_install_cleaner
    
    # --- ETAPA 1: OPERADORES ---
    log_header "ETAPA 1: INSTALANDO OPERADORES Y CRDS"
    cd "stages/01-operators"
    terraform init -no-color >> "$LOG_FILE" 2>&1
    
    log_step "Aplicando Operadores"
    if terraform apply -auto-approve -no-color 2>&1 | tee -a "$LOG_FILE"; then
        echo -e "${GREEN}✅ Operadores instalados.${NC}"
    else
        echo -e "${RED}❌ Fallo en Etapa 1. Revisa el log.${NC}"
        exit 1
    fi
    cd ../..

    # --- ESPERA INTELIGENTE DE CRDS ---
    log_step "⏳ Esperando registro de CRDs..."
    # Lista de CRDs críticos que necesitamos antes de la Etapa 2
    CRDS=("platformnavigators.integration.ibm.com" "apiconnectclusters.apiconnect.ibm.com" "queuemanagers.mq.ibm.com" "dashboards.appconnect.ibm.com" "datapowerservices.datapower.ibm.com" "certmanagers.operator.openshift.io")
    
    for CRD in "${CRDS[@]}"; do
        echo -ne "${YELLOW}Busando CRD: $CRD...${NC}"
        while ! oc get crd "$CRD" >/dev/null 2>&1; do
            echo -ne "."
            sleep 5
        done
        echo -e " ${GREEN}OK${NC}"
    done
    
    # --- ETAPA 2: INSTANCIAS ---
    log_header "ETAPA 2: DESPLEGANDO INSTANCIAS CP4I"
    cd "stages/02-instances"
    terraform init -no-color >> "$LOG_FILE" 2>&1
    sync_existing_resources # Ojo: esto necesita ajuste de rutas si usa TF state local
    
    log_step "Generando Plan Final"
    if terraform plan -no-color -out=tfplan 2>&1 | tee -a "$LOG_FILE"; then
        read -p "❓ ¿Aplicar cambios finales? (yes/no): " CONFIRM
        if [[ "$CONFIRM" == "yes" ]]; then
            if terraform apply -no-color "tfplan" 2>&1 | tee -a "$LOG_FILE"; then
                echo -e "${GREEN}✅ Instancias aplicadas con éxito.${NC}"
                cd ../.. # Volver a raíz

                # Fixes post-install
                if oc get commonservice common-service -n openshift-operators >/dev/null 2>&1; then
                     ACC=$(oc get commonservice common-service -n openshift-operators -o jsonpath='{.spec.license.accept}')
                     if [ "$ACC" != "true" ]; then
                         oc patch commonservice common-service -n openshift-operators --type=merge -p '{"spec": {"license": {"accept": true}}}' >> "$LOG_FILE" 2>&1
                     fi
                fi
                
                post_install_booster
                unblock_stuck_operator
                apply_nginx_hotfix
                validate_and_reveal_access
            else
                cd ../.. # Volver a raíz
                log "${RED}❌ Error: Falló la aplicación de instancias (terraform apply).${NC}"
                exit 1
            fi
        else
            cd ../..
        fi
    else
        cd ../..
        log "${RED}❌ Error en Plan Etapa 2.${NC}"
        exit 1
    fi
    ;;
  2)
    echo -e "${RED}⚠️  ESTA ACCIÓN BORRARÁ TODO.${NC}"
    read -p "Escribe 'DESTROY' para confirmar: " CONFIRM
    if [[ "$CONFIRM" == "DESTROY" ]]; then 
        if terraform destroy -auto-approve -no-color 2>&1 | tee -a "$LOG_FILE"; then
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