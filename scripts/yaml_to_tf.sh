#!/usr/bin/env bash

# Directorios
YAML_DIR="yamls"
TARGET_DIR="stages/02-instances"

mkdir -p "$TARGET_DIR"

echo "--- INICIANDO AUTOMATIZACIÓN YAML -> TF ---"

# Detectar comando de hash disponible
if command -v md5 >/dev/null 2>&1; then
    HASH_CMD="md5 -q"
elif command -v md5sum >/dev/null 2>&1; then
    HASH_CMD="md5sum"
else
    HASH_CMD="cksum"
fi

# Busqueda recursiva de yamls
find "$YAML_DIR" -name "*.yaml" -type f | while read -r yaml_file; do
    filename=$(basename "$yaml_file" .yaml)
    rel_path=$(echo "$yaml_file" | sed 's|^yamls/||' | sed 's|/|_|g' | sed 's|\.yaml$||')
    cleaned_name=$(echo "$rel_path" | sed 's/[-.]/_/g')
    
    # Intentamos extraer el nombre del recurso de Terraform si ya existe en algun archivo manual
    # Buscamos 'resource "kubernetes_manifest" "IDENTIFIER"'
    # El usuario menciono "apic_cluster", vamos a ver si coincide
    
    tf_file="$TARGET_DIR/z_auto_${cleaned_name}.tf"
    
    # Comprobar si el identificador gen_${cleaned_name} ya existe en algun .tf NO auto-generado
    # O si el usuario ya tiene un recurso manual para este YAML (heuristicamente)
    if grep -r "resource \"kubernetes_manifest\"" "$TARGET_DIR" --exclude="z_auto_*" | grep -q "\"${cleaned_name}\""; then
        echo "⏭️  Saltando $yaml_file: Ya existe un recurso manual con nombre '${cleaned_name}'"
        continue
    fi

    # Caso especial para apic_cluster (el usuario lo menciono)
    if [[ "$cleaned_name" == *"cluster_medium"* ]] && grep -r "resource \"kubernetes_manifest\" \"apic_cluster\"" "$TARGET_DIR" --exclude="z_auto_*" >/dev/null 2>&1; then
        echo "⏭️  Saltando $yaml_file: Detectado recurso manual 'apic_cluster' en cp4i.tf"
        continue
    fi
    
    # Calcular hash actual
    current_hash=$($HASH_CMD "$yaml_file" | awk '{print $1}')
    
    # Verificar si necesita actualización
    needs_update=1
    if [ -f "$tf_file" ]; then
        stored_hash=$(grep "# YAML-HASH:" "$tf_file" | awk '{print $3}')
        if [ "$current_hash" == "$stored_hash" ]; then
            needs_update=0
        fi
    fi
    
    if [ $needs_update -eq 1 ]; then
        echo "🔄 Generando/Actualizando: $tf_file (desde $yaml_file)"
        cat <<EOF > "$tf_file"
# AUTO-GENERATED from $yaml_file
# YAML-HASH: $current_hash
resource "kubernetes_manifest" "gen_${cleaned_name}" {
  manifest = yamldecode(file("\${path.module}/../../$yaml_file"))
}
EOF
    else
        echo "✅ Sin cambios: $tf_file"
    fi
done

echo "--- FIN AUTOMATIZACIÓN ---"
