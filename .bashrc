alias ls="ls -trlAh"

repo_context() {
    local OUT_FILE="/tmp/repo_context_dump.xml"
    local MAX_SIZE="64k"

    echo "<codebase>" > "$OUT_FILE"

    find . -type f -size -"$MAX_SIZE" \
        -not -path '*/.git/*' \
        -not -path '*/node_modules/*' \
        -not -path '*/target/*' \
        \( \
           -name "*.rs" \
        -o -name "*.txt" \
        -o -name "*.md" \
        -o -name "*.sql" \
        -o -name "*.nix" \
        -o -name "*.sh" \
        -o -name "*.toml" \
        -o -name "*.json" \
        -o -name "*.yaml" \
        \) -print0 | while IFS= read -r -d '' file; do

        clean_name="${file#./}"
        echo "Processing: $clean_name" >&2
        echo "  <file name=\"$clean_name\">" >> "$OUT_FILE"
        cat "$file" >> "$OUT_FILE"
        echo "" >> "$OUT_FILE"
        echo "  </file>" >> "$OUT_FILE"
    done

    echo "</codebase>" >> "$OUT_FILE"

    if command -v xclip &> /dev/null; then
        xclip -selection clipboard < "$OUT_FILE"
        echo "------------------------------------------------"
        echo "Context copied to clipboard!"
        echo "Size: $(du -h "$OUT_FILE" | cut -f1)"
        echo "------------------------------------------------"
    else
        echo "Error: xclip not found. Result saved to $OUT_FILE"
    fi
}
