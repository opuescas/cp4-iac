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
    DL_ROUTE=$(oc get route -n "$APIC_NAMESPACE" | grep "${APIC_INSTANCE_PREFIX}-mgmt" | head -1 | awk '{print $2}')

    if [ -z "$DL_ROUTE" ]; then
        log_error "No se pudo determinar la ruta del management de APIC."
        log_error "Por favor, descarga la CLI apic manualmente desde:"
        log_error "  Cloud Manager UI > Perfil > Descargas > API Connect Toolkit"
        log_error "  Guarda el binario como 'apic' en el PATH o en: $APIC_CLI_PATH"
        exit 1
    fi

    local OS
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    local ARCH
    ARCH=$(uname -m)
    [ "$ARCH" = "x86_64" ] && ARCH="amd64"
    [ "$ARCH" = "arm64" ]  && ARCH="arm64"

    local DOWNLOAD_URL="https://$DL_ROUTE/packages/toolkit/v10/${OS}_${ARCH}"
    log "Descargando apic desde: $DOWNLOAD_URL"

    if curl -sSfLk -o "$APIC_CLI_PATH" "$DOWNLOAD_URL" 2>/dev/null; then
        chmod +x "$APIC_CLI_PATH"
        APIC_CLI="$APIC_CLI_PATH"
        log "✅ apic descargada en: $APIC_CLI_PATH"
    else
        log_error "Descarga fallida. Por favor instala la CLI apic manualmente."
        log_error "URL intentada: $DOWNLOAD_URL"
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

    local ADMIN_USER
    local ADMIN_PASS
    ADMIN_USER=$(oc extract secret/"$APIC_MGMT_SECRET" -n "$APIC_NAMESPACE" --to=- --keys=email 2>/dev/null || echo "admin@apiconnect.net")
    ADMIN_PASS=$(oc extract secret/"$APIC_MGMT_SECRET" -n "$APIC_NAMESPACE" --to=- --keys=password 2>/dev/null)

    if [ -z "$ADMIN_PASS" ]; then
        log_error "No se pudo obtener la contraseña del secreto '$APIC_MGMT_SECRET'."
        exit 1
    fi

    log "Detectando identity providers disponibles (scope admin)..."
    $APIC_CLI identity-providers:list \
        --scope admin \
        --server "$APIC_PLATFORM_API" \
        --output json 2>/dev/null > /tmp/apic_idp_admin.json || true

    local REALM="admin/default-idp-1"
    if [ -f /tmp/apic_idp_admin.json ]; then
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
    [ "$CONFIRM" != "yes" ] && { log_warn "Cancelado."; exit 0; }
}

# =============================================================================
# STEP 5: Obtener token de sesión apic para llamadas REST directas
# =============================================================================
get_apic_token() {
    local CREDS_FILE="$HOME/.apiconnect/credentials.json"
    if [ ! -f "$CREDS_FILE" ]; then
        log_error "No se encontró $CREDS_FILE. Asegúrate de haber hecho login."
        exit 1
    fi

    APIC_TOKEN=$(python3 -c "
import json, sys
data = json.load(open('$CREDS_FILE'))
servers = data.get('cloud_settings', {}).get('servers', [])
for s in servers:
    if '$APIC_PLATFORM_API' in s.get('server', ''):
        tok = s.get('access_token', '')
        if tok:
            print(tok)
            sys.exit(0)
print('')
" 2>/dev/null || echo "")

    if [ -z "$APIC_TOKEN" ]; then
        log_error "No se pudo obtener el token de sesión de apic."
        exit 1
    fi
}

# =============================================================================
# STEP 6: Crear la Provider Organization
# =============================================================================
create_provider_org() {
    log_header "Creando Provider Organization: $APIC_ORG_NAME"

    # Verificar si ya existe
    local EXISTS
    EXISTS=$($APIC_CLI orgs:get "$APIC_ORG_NAME" \
        --server "$APIC_PLATFORM_API" \
        --output json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null || echo "")

    if [ "$EXISTS" = "$APIC_ORG_NAME" ]; then
        log_error "❌ La organización '$APIC_ORG_NAME' ya existe. Abortando."
        log_error "   Para eliminarla: apic orgs:delete $APIC_ORG_NAME --server $APIC_PLATFORM_API"
        exit 1
    fi

    cat > /tmp/apic_org.yaml <<EOF
type: org
api_version: v2
name: ${APIC_ORG_NAME}
title: ${APIC_ORG_TITLE}
org_type: provider
EOF

    $APIC_CLI orgs:create /tmp/apic_org.yaml \
        --server "$APIC_PLATFORM_API"

    log "✅ Provider Organization '$APIC_ORG_NAME' creada."
}

# =============================================================================
# STEP 7: Crear usuario en API Manager Local User Registry via REST
# =============================================================================
create_apim_user() {
    log_header "Creando usuario en API Manager User Registry"
    get_apic_token

    # Obtener URL del LUR de la org
    log "Buscando user registries en la org '$APIC_ORG_NAME'..."
    local REGISTRIES_RESP
    REGISTRIES_RESP=$(curl -sSk \
        -H "Accept: application/json" \
        -H "Authorization: Bearer $APIC_TOKEN" \
        "https://$APIC_PLATFORM_API/api/orgs/$APIC_ORG_NAME/user-registries" 2>/dev/null)

    local LUR_BASE_URL
    LUR_BASE_URL=$(echo "$REGISTRIES_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('results', []):
    if r.get('registry_type') in ('local', 'lur') or r.get('name') in ('api-manager-lur', 'default-lur'):
        print(r.get('url', '').rstrip('/'))
        break
" 2>/dev/null || echo "")

    if [ -z "$LUR_BASE_URL" ]; then
        LUR_BASE_URL="https://$APIC_PLATFORM_API/api/orgs/$APIC_ORG_NAME/user-registries/api-manager-lur"
        log_warn "No se encontró LUR automáticamente. Usando URL por defecto: $LUR_BASE_URL"
    fi

    log "LUR URL: $LUR_BASE_URL"

    # Verificar si el usuario ya existe
    local USER_EXISTS
    USER_EXISTS=$(curl -sSk \
        -H "Authorization: Bearer $APIC_TOKEN" \
        "$LUR_BASE_URL/users/$APIC_OWNER_USER" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('username',''))" 2>/dev/null || echo "")

    if [ "$USER_EXISTS" = "$APIC_OWNER_USER" ]; then
        log_error "❌ El usuario '$APIC_OWNER_USER' ya existe. Abortando."
        exit 1
    fi

    # Crear el usuario
    log "Creando usuario '$APIC_OWNER_USER'..."
    local CREATE_RESP
    CREATE_RESP=$(curl -sSk -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $APIC_TOKEN" \
        -d "{
            \"username\": \"$APIC_OWNER_USER\",
            \"email\": \"$APIC_OWNER_EMAIL\",
            \"first_name\": \"$APIC_OWNER_FIRST\",
            \"last_name\": \"$APIC_OWNER_LAST\",
            \"password\": \"$APIC_OWNER_PASS\"
        }" \
        "$LUR_BASE_URL/users" 2>/dev/null)

    local CREATED_USER
    CREATED_USER=$(echo "$CREATE_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('username',''))" 2>/dev/null || echo "")

    if [ -z "$CREATED_USER" ]; then
        log_error "❌ Error al crear el usuario. Respuesta del servidor:"
        echo "$CREATE_RESP" | python3 -m json.tool 2>/dev/null || echo "$CREATE_RESP"
        exit 1
    fi

    # Guardar URL del usuario para el siguiente paso
    USER_URL=$(echo "$CREATE_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('url',''))" 2>/dev/null || echo "")
    log "✅ Usuario '$APIC_OWNER_USER' creado. URL: $USER_URL"
}

# =============================================================================
# STEP 8: Asignar usuario como member-administrator + transferir ownership
# =============================================================================
assign_org_owner() {
    log_header "Asignando usuario como owner de la organización"

    cat > /tmp/apic_member.yaml <<EOF
type: member
api_version: v2
user:
  url: "${USER_URL}"
  registry_url: "${LUR_BASE_URL:-https://$APIC_PLATFORM_API/api/orgs/$APIC_ORG_NAME/user-registries/api-manager-lur}"
  username: "${APIC_OWNER_USER}"
role_urls:
  - "https://$APIC_PLATFORM_API/api/orgs/$APIC_ORG_NAME/roles/administrator"
EOF

    $APIC_CLI members:create /tmp/apic_member.yaml \
        --server "$APIC_PLATFORM_API" \
        --org "$APIC_ORG_NAME" \
        --scope org 2>/dev/null && log "✅ Usuario agregado como administrator." || log_warn "members:create requirió fallback."

    # Transferir ownership si tenemos la URL del usuario
    if [ -n "$USER_URL" ]; then
        log "Transfiriendo ownership de la org al nuevo usuario..."
        cat > /tmp/apic_transfer.yaml <<EOF
new_owner_user_url: "${USER_URL}"
EOF
        $APIC_CLI orgs:transfer-owner "$APIC_ORG_NAME" \
            --server "$APIC_PLATFORM_API" \
            /tmp/apic_transfer.yaml 2>/dev/null \
            && log "✅ Ownership transferido a '$APIC_OWNER_USER'." \
            || log_warn "Transfer-owner falló o no disponible. El usuario permanece como administrator."
    fi
}

# =============================================================================
# STEP 9: Resumen y verificación
# =============================================================================
verify_setup() {
    log_header "Resumen Final"

    echo -e "${CYAN}--- Provider Organizations ---${NC}"
    $APIC_CLI orgs:list --server "$APIC_PLATFORM_API" 2>/dev/null || true

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

    # Limpiar archivos temporales con datos sensibles
    rm -f /tmp/apic_org.yaml /tmp/apic_member.yaml /tmp/apic_transfer.yaml /tmp/apic_idp_admin.json
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo -e "${BLUE}=== INICIALIZACIÓN DE IBM API CONNECT ===${NC}"
    echo ""

    ensure_apic_cli
    get_platform_api
    login_admin
    collect_org_params
    create_provider_org
    create_apim_user
    assign_org_owner
    verify_setup
}

main "$@"
