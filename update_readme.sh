#!/usr/bin/env bash
###############################################################################
#  update_readme.sh — Génère automatiquement la section Scripts du README
#
#  Ce script :
#    1. Parcourt tous les fichiers .sh dans le dossier scripts/
#    2. Extrait le nom, la description courte et la section Usage de chaque script
#    3. Remplace le contenu entre les balises <!-- SCRIPTS_START --> et
#       <!-- SCRIPTS_END --> dans README.md
#
#  Usage :
#    ./update_readme.sh
#    # Ou via GitHub Actions (automatique à chaque push)
###############################################################################
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"
README="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/README.md"
MARKER_START="<!-- SCRIPTS_START -->"
MARKER_END="<!-- SCRIPTS_END -->"

# Build the new scripts section
build_scripts_section() {
    echo "$MARKER_START"
    echo ""
    echo "## 📂 Scripts disponibles"
    echo ""

    local found=0
    for script in "$SCRIPTS_DIR"/*.sh; do
        [[ -f "$script" ]] || continue
        found=1

        local filename
        filename="$(basename "$script")"

        # Extract short description: line matching " <name> — <desc>" or "# <name> — <desc>"
        local short_desc
        short_desc=$(grep -m1 '—\|--' "$script" | sed 's/^#[[:space:]]*//' | sed 's/^[[:space:]]*//' || true)

        # Extract usage block: lines between "#  Usage :" and the closing "###" block
        local usage
        usage=$(awk '
            /^#[[:space:]]*Usage[[:space:]]*:/ { in_usage=1; next }
            in_usage && /^###/ { exit }
            in_usage && /^[^#]/ { exit }
            in_usage { sub(/^#[[:space:]]?[[:space:]]?/, ""); print }
        ' "$script" | sed '/^[[:space:]]*$/d')

        # Extract full description block (lines between header and "Usage" or closing ###)
        # Skip the first non-empty line (already used as short_desc)
        local full_desc
        full_desc=$(awk '
            /^###/ && header_done { exit }
            /^###/ { header_done=1; first_skipped=0; next }
            header_done && /^#[[:space:]]*Usage/ { exit }
            header_done && /^#[[:space:]]*PHILOSOPHIE/ { exit }
            header_done && /^[^#]/ { exit }
            header_done {
                line = $0
                sub(/^#[[:space:]]?[[:space:]]?/, "", line)
                # Skip the first non-empty line (short desc already extracted)
                if (!first_skipped && line != "") { first_skipped=1; next }
                if (line != "") print line
            }
        ' "$script" || true)

        echo "### \`$filename\`"
        echo ""

        if [[ -n "$short_desc" ]]; then
            echo "> $short_desc"
            echo ""
        fi

        if [[ -n "$full_desc" ]]; then
            echo "$full_desc"
            echo ""
        fi

        if [[ -n "$usage" ]]; then
            echo "**Usage :**"
            echo '```bash'
            echo "$usage"
            echo '```'
            echo ""
        fi

        echo "---"
        echo ""
    done

    if [[ $found -eq 0 ]]; then
        echo "_Aucun script disponible pour le moment._"
        echo ""
    fi

    echo "$MARKER_END"
}

# Replace the section in README.md between the markers
update_readme() {
    local new_section
    new_section="$(build_scripts_section)"

    if ! grep -q "$MARKER_START" "$README"; then
        echo "Markers not found in README.md — appending scripts section."
        printf '\n%s\n' "$new_section" >> "$README"
        return
    fi

    # Replace between markers (inclusive)
    local tmp
    tmp="$(mktemp)"
    awk -v new="$new_section" '
        /<!-- SCRIPTS_START -->/ { print new; skip=1; next }
        /<!-- SCRIPTS_END -->/ { skip=0; next }
        !skip { print }
    ' "$README" > "$tmp"
    mv "$tmp" "$README"
}

update_readme
echo "README.md updated successfully."
