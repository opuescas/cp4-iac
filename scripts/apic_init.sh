#!/usr/bin/env bash
# =============================================================================
# apic_init.sh - Configuración Inicial de IBM API Connect
# =============================================================================
# Propósito: Automatiza la inicialización post-instalación de APIC:
#   1. Verifica/descarga la CLI `apic`
#   2. Obtiene el endpoint de Platform API desde el clúster
#   3. Crea la Provider Organization
#   4. Crea un usuario en el API Manager Local User Registry
#   5. Asigna el usuario como owner/miembro de la org
#
# IMPORTANTE: Este script requiere `oc` autenticado en el clúster y
#             acceso al namespace `cp4i`.
# =============================================================================

set -e

# --- COLORES ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[1;34m'
NC='\033[0m'

# --- PARÁMETROS CONFIGURABLES ---
APIC_NAMESPACE="cp4i"
APIC_INSTANCE_PREFIX="large-cdt"
APIC_MGMT_SECRET="large-cdt-mgmt-admin-pass"

# Datos de la organización (sobreescribibles via env vars)
APIC_ORG_NAME="${APIC_ORG_NAME:-}"
APIC_ORG_TITLE="${APIC_ORG_TITLE:-}"
APIC_OWNER_USER="${APIC_OWNER_USER:-}"
APIC_OWNER_PASS="${APIC_OWNER_PASS:-}"
APIC_OWNER_EMAIL="${APIC_OWNER_EMAIL:-}"
APIC_OWNER_FIRST="${APIC_OWNER_FIRST:-}"
APIC_OWNER_LAST="${APIC_OWNER_LAST:-}"

# CLI path
APIC_CLI_PATH="${APIC_CLI_PATH:-./apic}"
APIC_CLI=""

log()        { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()  { echo -e "${RED}[ERROR]${NC} $1"; }
log_header() { echo -e "\n${BLUE}==== $1 ====${NC}"; }

# =============================================================================
# STEP 0: Verificar autenticación OC
# =============================================================================
check_oc_auth() {
    log_header "Verificando sesión OC"
    if ! oc whoami &>/dev/null; then
        echo -e "${RED}[ERROR]${NC} No estás autenticado en el clúster OpenShift."
        echo ""
        echo -e "${CYAN}Para autenticarte, ejecuta:${NC}"
        echo "  oc login https://api.itz-egs1i2.hub01-lb.techzone.ibm.com:6443"
        echo "  (Usuario: kubeadmin, o el que uses para administrar el clúster)"
        echo ""
        echo -e "${YELLOW}Si la CLI apic ya está instalada y quieres omitir OC,${NC}"
        echo -e "${YELLOW}agrega APIC_PLATFORM_API=<hostname> como variable de entorno.${NC}"
        exit 1
    fi
    local USER
    USER=$(oc whoami 2>/dev/null)
    local SERVER
    SERVER=$(oc whoami --show-server 2>/dev/null)
    log "✅ OC autenticado como: $USER"
    log "   Servidor: $SERVER"
}

# =============================================================================
# STEP 1: Verificar/Descargar CLI apic
# =============================================================================
ensure_apic_cli() {
    log_header "Verificando CLI apic"

    if command -v apic &>/dev/null; then
        APIC_CLI="apic"
        log "✅ apic encontrado en PATH: $(which apic)"
        apic version 2>/dev/null | head -1 || true
        return
    fi

    if [ -f "$APIC_CLI_PATH" ] && [ -x "$APIC_CLI_PATH" ]; then
        APIC_CLI="$APIC_CLI_PATH"
        log "✅ apic encontrado localmente: $APIC_CLI_PATH"
        return
    fi

    log_warn "CLI apic no encontrada. Intentando obtenerla desde el clúster..."

    local DL_ROUTE
    # Intentar obtener la ruta del management desde OC
    DL_ROUTE=$(oc get route -n "$APIC_NAMESPACE" --no-headers 2>/dev/null | grep "${APIC_INSTANCE_PREFIX}-mgmt" | head -1 | awk '{print $2}' || echo "")

    # Fallback: usar la ruta conocida del management (hardcoded desde despliegue TF)
    if [ -z "$DL_ROUTE" ]; then
        log_warn "No se pudo obtener la ruta via OC. Usando ruta conocida del despliegue..."
        DL_ROUTE=$(oc get route -n "$APIC_NAMESPACE" 2>/dev/null | grep -i "mgmt-admin\|mgmt-platform" | head -1 | awk '{print $2}' || echo "")
    fi

    if [ -z "$DL_ROUTE" ]; then
        log_error "No se pudo determinar la ruta del management de APIC."
        log_error "Por favor, descarga la CLI apic manualmente desde:"
        log_error "  Cloud Manager UI > Perfil > Descargas > API Connect Toolkit"
        log_error "  Guarda el binario como 'apic' en el PATH o en: $APIC_CLI_PATH"
        log_error ""
        log_error "URL directa (basada en tu despliegue actual):"
        log_error "  https://large-cdt-mgmt-admin-cp4i.apps.itz-egs1i2.hub01-lb.techzone.ibm.com"
        log_error "  Login > Perfil > Descargas"
        exit 1
    fi

    local OS
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    local ARCH
    ARCH=$(uname -m)
    [ "$ARCH" = "x86_64" ] && ARCH="amd64"
    [ "$ARCH" = "arm64" ]  && ARCH="arm64"

    # La URL de toolkit en CP4I management usa el portal de admin
    # Extraer el dominio base (sin el prefijo de ruta del mgmt-admin)
    local BASE_DOMAIN
    BASE_DOMAIN=$(echo "$DL_ROUTE" | sed 's/^[^.]*\.//')
    local TOOLKIT_HOST="${APIC_INSTANCE_PREFIX}-mgmt-platform-api-${APIC_NAMESPACE}.${BASE_DOMAIN}"

    local DOWNLOAD_URL="https://$TOOLKIT_HOST/packages/toolkit/v10/${OS}_${ARCH}"
    log "Descargando apic desde: $DOWNLOAD_URL"

    if curl -sSfLk --max-time 30 -o "$APIC_CLI_PATH" "$DOWNLOAD_URL" 2>/dev/null; then
        chmod +x "$APIC_CLI_PATH"
        APIC_CLI="$APIC_CLI_PATH"
        log "✅ apic descargada en: $APIC_CLI_PATH"
    else
        log_error "Descarga fallida. Por favor instala la CLI apic manualmente."
        log_error "URL intentada: $DOWNLOAD_URL"
        log_error ""
        log_error "Alternativas:"
        log_error "  1. Abre https://large-cdt-mgmt-admin-cp4i.apps.itz-egs1i2.hub01-lb.techzone.ibm.com"
        log_error "     Login con admin@apiconnect.net > Perfil > Descargas > API Connect Toolkit (mac)"
        log_error "  2. mv ~/Downloads/apic_mac /usr/local/bin/apic && chmod +x /usr/local/bin/apic"
        exit 1
    fi
}

# =============================================================================
# STEP 2: Obtener Platform API endpoint
# =============================================================================
get_platform_api() {
    log_header "Obteniendo Platform API Endpoint"

    local MGMT_ROUTE
    MGMT_ROUTE=$(oc get route -n "$APIC_NAMESPACE" --no-headers 2>/dev/null | grep "${APIC_INSTANCE_PREFIX}-mgmt-platform-api\|mgmt-platform-api" | awk '{print $2}' | head -1)

    if [ -z "$MGMT_ROUTE" ]; then
        MGMT_ROUTE=$(oc get route -n "$APIC_NAMESPACE" -l "app.kubernetes.io/name=platform-api" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
    fi

    if [ -z "$MGMT_ROUTE" ]; then
        log_warn "No se detectó automáticamente la ruta Platform API."
        echo ""
        echo "Rutas disponibles en namespace $APIC_NAMESPACE:"
        oc get routes -n "$APIC_NAMESPACE" --no-headers | awk '{printf "  %-50s -> https://%s\n", $1, $2}'
        echo ""
        read -rp "Introduce el hostname de la Platform API (sin https://): " MGMT_ROUTE
    fi

    APIC_PLATFORM_API="$MGMT_ROUTE"
    log "✅ Platform API: https://$APIC_PLATFORM_API"
}

# =============================================================================
# STEP 3: Login scope=admin en el Cloud Manager
# =============================================================================
login_admin() {
    log_header "Login en Cloud Manager (scope admin)"

    local ADMIN_USER="admin"
    local ADMIN_PASS
    ADMIN_PASS=$(oc get secret "$APIC_MGMT_SECRET" -n "$APIC_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | python3 -m base64 -d)

    if [ -z "$ADMIN_PASS" ]; then
        log_error "No se pudo obtener la contraseña del secreto '$APIC_MGMT_SECRET'."
        exit 1
    fi
    log "Usuario admin: $ADMIN_USER"

    # Obtener client_id y secret del CLI client credentials
    local CLI_CRED_SECRET="${APIC_INSTANCE_PREFIX}-mgmt-ccli-cred"
    local CLI_CRED
    CLI_CRED=$(oc extract secret/"$CLI_CRED_SECRET" -n "$APIC_NAMESPACE" --to=- 2>/dev/null)
    local CLI_ID
    CLI_ID=$(echo "$CLI_CRED" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
    local CLI_SEC
    CLI_SEC=$(echo "$CLI_CRED" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('secret',''))" 2>/dev/null || echo "")

    if [ -z "$CLI_ID" ]; then
        log_warn "No se encontró $CLI_CRED_SECRET. Usando client credentials por defecto."
        CLI_ID="caa87d9a-8cd7-4686-8b6e-ee2cdc5ee267"
        CLI_SEC="3ecff363-cd74-4bde-9b54-72b9d4f764e0"
    fi

    log "Detectando identity providers disponibles (scope admin)..."
    # Usar la apic CLI para detectar IDPs - pasa el usuario/pass
    $APIC_CLI identity-providers:list \
        --scope admin \
        --server "$APIC_PLATFORM_API" \
        --output json 2>/dev/null > /tmp/apic_idp_admin.json || true

    local REALM="admin/default-idp-1"
    if [ -f /tmp/apic_idp_admin.json ] && [ -s /tmp/apic_idp_admin.json ]; then
        local DETECTED
        DETECTED=$(python3 -c "
import json, sys
try:
    d = json.load(open('/tmp/apic_idp_admin.json'))
    results = d.get('results', [])
    if results:
        print(results[0].get('name', ''))
except:
    pass
" 2>/dev/null || echo "")
        [ -n "$DETECTED" ] && REALM="admin/$DETECTED"
    fi

    log "Usando realm: $REALM"
    $APIC_CLI login \
        --server "$APIC_PLATFORM_API" \
        --username "$ADMIN_USER" \
        --password "$ADMIN_PASS" \
        --realm "$REALM"

    log "✅ Login en Cloud Manager exitoso."
}


# =============================================================================
# STEP 4: Recopilar parámetros interactivamente si no están definidos
# =============================================================================
collect_org_params() {
    log_header "Configuración de la Provider Organization y Owner"

    if [ -z "$APIC_ORG_NAME" ]; then
        read -rp "  Nombre de la org (slug, sin espacios, ej: cp4i-production): " APIC_ORG_NAME
    fi
    if [ -z "$APIC_ORG_TITLE" ]; then
        read -rp "  Título descriptivo de la org (ej: CP4I Production): " APIC_ORG_TITLE
    fi

    echo ""
    echo "  --- Datos del Owner (nuevo usuario en API Manager User Registry) ---"
    if [ -z "$APIC_OWNER_USER" ]; then
        read -rp "  Username: " APIC_OWNER_USER
    fi
    if [ -z "$APIC_OWNER_EMAIL" ]; then
        read -rp "  Email: " APIC_OWNER_EMAIL
    fi
    if [ -z "$APIC_OWNER_FIRST" ]; then
        read -rp "  Nombre (First Name): " APIC_OWNER_FIRST
    fi
    if [ -z "$APIC_OWNER_LAST" ]; then
        read -rp "  Apellido (Last Name): " APIC_OWNER_LAST
    fi
    if [ -z "$APIC_OWNER_PASS" ]; then
        read -rsp "  Password (mín 8 chars, mayúscula + número): " APIC_OWNER_PASS
        echo ""
    fi

    echo ""
    echo -e "${CYAN}Resumen de configuración:${NC}"
    echo "   Org Name:    $APIC_ORG_NAME"
    echo "   Org Title:   $APIC_ORG_TITLE"
    echo "   Owner User:  $APIC_OWNER_USER"
    echo "   Owner Email: $APIC_OWNER_EMAIL"
    echo "   Owner Name:  $APIC_OWNER_FIRST $APIC_OWNER_LAST"
    echo ""
    read -rp "¿Confirmar y continuar? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_warn "Cancelado."
        exit 0
    fi
}

# =============================================================================
# STEP 5: Obtener token de sesión apic para llamadas REST directas
# =============================================================================
get_apic_token() {
    local TOKEN_FILE="$HOME/.apiconnect/token"
    local CREDS_FILE="$HOME/.apiconnect/credentials.json"
    APIC_TOKEN=""

    if [ -f "$TOKEN_FILE" ]; then
        log "Buscando token en $TOKEN_FILE..."
        APIC_TOKEN=$(python3 -c "
import re, sys
try:
    content = open('$TOKEN_FILE').read()
    # Busca la sección correspondiente a $APIC_PLATFORM_API/api: |
    # y luego extrae el access_token dentro de esa sección
    pattern = re.escape('$APIC_PLATFORM_API') + r'/api:\s*\|\n(.*?)(?=\n\S|\Z)'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        token_match = re.search(r'access_token:\s*([^\s\n]+)', match.group(1))
        if token_match:
            print(token_match.group(1))
            sys.exit(0)
    # Fallback: buscar cualquier access_token en el archivo
    tokens = re.findall(r'access_token:\s*([^\s\n]+)', content)
    if tokens:
        print(tokens[0])
        sys.exit(0)
except Exception as e:
    pass
print('')
" 2>/dev/null || echo "")
    fi

    if [ -z "$APIC_TOKEN" ] && [ -f "$CREDS_FILE" ]; then
        log "Buscando token en $CREDS_FILE..."
        APIC_TOKEN=$(python3 -c "
import json, sys
try:
    data = json.load(open('$CREDS_FILE'))
    servers = data.get('cloud_settings', {}).get('servers', [])
    for s in servers:
        if '$APIC_PLATFORM_API' in s.get('server', ''):
            tok = s.get('access_token', '')
            if tok:
                print(tok)
                sys.exit(0)
except Exception as e:
    pass
print('')
" 2>/dev/null || echo "")
    fi

    if [ -z "$APIC_TOKEN" ]; then
        log_error "No se pudo obtener el token de sesión de apic desde ~/.apiconnect/token o ~/.apiconnect/credentials.json."
        exit 1
    fi
    log "✅ Token de sesión de APIC obtenido correctamente."
}

# =============================================================================
# STEP 6: Crear usuario en API Manager Local User Registry
# =============================================================================
create_apim_user() {
    log_header "Creando usuario en API Manager User Registry"

    # Verificar si el usuario ya existe
    local USER_GET_OUT
    USER_GET_OUT=$($APIC_CLI users:get "$APIC_OWNER_USER" \
        --server "$APIC_PLATFORM_API" \
        --org admin \
        --user-registry api-manager-lur 2>&1) || true

    if [[ "$USER_GET_OUT" == *"https://"* ]]; then
        USER_URL=$(echo "$USER_GET_OUT" | awk '{print $3}')
        log "⚠️ El usuario '$APIC_OWNER_USER' ya existe en 'api-manager-lur'. Usando su URL existente: $USER_URL"
    else
        log "Creando usuario '$APIC_OWNER_USER'..."
        cat > /tmp/apic_user.yaml <<EOF
email: ${APIC_OWNER_EMAIL}
first_name: ${APIC_OWNER_FIRST}
last_name: ${APIC_OWNER_LAST}
name: ${APIC_OWNER_USER}
password: ${APIC_OWNER_PASS}
username: ${APIC_OWNER_USER}
EOF
        local CREATE_RESP
        CREATE_RESP=$($APIC_CLI users:create /tmp/apic_user.yaml \
            --server "$APIC_PLATFORM_API" \
            --org admin \
            --user-registry api-manager-lur 2>&1)
        USER_URL=$(echo "$CREATE_RESP" | awk '{print $3}')
        if [ -z "$USER_URL" ]; then
            log_error "❌ Error al crear el usuario. Respuesta:"
            echo "$CREATE_RESP"
            exit 1
        fi
        log "✅ Usuario '$APIC_OWNER_USER' creado. URL: $USER_URL"
    fi
}

# =============================================================================
# STEP 7: Crear la Provider Organization
# =============================================================================
create_provider_org() {
    log_header "Creando Provider Organization: $APIC_ORG_NAME"

    # Verificar si ya existe
    local EXISTS_OUT
    EXISTS_OUT=$($APIC_CLI orgs:get "$APIC_ORG_NAME" \
        --server "$APIC_PLATFORM_API" 2>&1) || true

    if [[ "$EXISTS_OUT" == *"https://"* ]]; then
        log_error "❌ La organización '$APIC_ORG_NAME' ya existe. Abortando."
        log_error "   Para eliminarla: apic orgs:delete $APIC_ORG_NAME --server $APIC_PLATFORM_API"
        exit 1
    fi

    if [ -z "$USER_URL" ]; then
        log_error "❌ URL del owner no disponible. No se puede crear la organización."
        exit 1
    fi

    cat > /tmp/apic_org.yaml <<EOF
type: org
api_version: 2.0.0
name: ${APIC_ORG_NAME}
title: ${APIC_ORG_TITLE}
org_type: provider
owner_url: ${USER_URL}
EOF

    $APIC_CLI orgs:create /tmp/apic_org.yaml \
        --server "$APIC_PLATFORM_API"

    log "✅ Provider Organization '$APIC_ORG_NAME' creada con owner '$APIC_OWNER_USER'."
}

# =============================================================================
# STEP 8: Resumen y verificación
# =============================================================================
verify_setup() {
    log_header "Resumen Final y Verificación de Credenciales"

    # Log in as the new owner user to check if they can access their new organization
    log "Probando inicio de sesión con el nuevo usuario..."
    if $APIC_CLI login \
        --server "$APIC_PLATFORM_API" \
        --username "$APIC_OWNER_USER" \
        --password "$APIC_OWNER_PASS" \
        --realm "provider/default-idp-2" >/dev/null 2>&1; then
        log "✅ Login verificado para '$APIC_OWNER_USER' (realm: provider/default-idp-2)."
    else
        log_warn "⚠️ No se pudo verificar el inicio de sesión del usuario '$APIC_OWNER_USER'."
    fi

    echo ""
    echo -e "${CYAN}--- Miembros de '$APIC_ORG_NAME' ---${NC}"
    $APIC_CLI members:list \
        --server "$APIC_PLATFORM_API" \
        --org "$APIC_ORG_NAME" \
        --scope org 2>/dev/null || true

    echo ""
    local APIM_URL
    APIM_URL=$(oc get route "${APIC_INSTANCE_PREFIX}-mgmt-api-manager" -n "$APIC_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -z "$APIM_URL" ]; then
        APIM_URL=$(oc get route -n "$APIC_NAMESPACE" | grep "api-manager" | awk '{print $2}' | head -1)
    fi

    echo -e "${GREEN}✅ Inicialización de APIC completada.${NC}"
    echo ""
    echo -e "${CYAN}Acceso al API Manager con el nuevo usuario:${NC}"
    echo -e "  🔗 URL:      https://$APIM_URL"
    echo -e "  👤 Usuario:  $APIC_OWNER_USER"
    echo -e "  🔑 Password: $APIC_OWNER_PASS"
    echo ""

    # Limpiar archivos temporales
    rm -f /tmp/apic_org.yaml /tmp/apic_user.yaml /tmp/apic_idp_admin.json
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo -e "${BLUE}=== INICIALIZACIÓN DE IBM API CONNECT ===${NC}"
    echo ""

    check_oc_auth
    ensure_apic_cli
    get_platform_api
    login_admin
    collect_org_params
    create_apim_user
    create_provider_org
    verify_setup
}

main "$@"
