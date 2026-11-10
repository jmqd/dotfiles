alias ls="ls -trlAh"

_repo_context_dump() {
    local MAX_SIZE="64k"

    echo "<codebase>"

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
        echo "  <file name=\"$clean_name\">"
        cat "$file"
        echo ""
        echo "  </file>"
    done

    echo "</codebase>"
}

# The dump can hold private source, so it never lands in a shared,
# predictable path: it goes straight to the clipboard, or to a private
# mktemp file when xclip is missing.
repo_context() {
    local dump out_file
    dump="$(_repo_context_dump)" || return 1

    if command -v xclip &> /dev/null; then
        printf '%s\n' "$dump" | xclip -selection clipboard
        echo "------------------------------------------------"
        echo "Context copied to clipboard!"
        echo "Size: ${#dump} characters"
        echo "------------------------------------------------"
    else
        out_file="$(mktemp "${TMPDIR:-/tmp}/repo_context.XXXXXX")" || return 1
        printf '%s\n' "$dump" > "$out_file"
        echo "Error: xclip not found. Result saved to $out_file"
    fi
}
