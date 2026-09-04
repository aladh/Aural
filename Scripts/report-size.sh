#!/bin/bash
set -euo pipefail

# Reports release build size for the Stage 1 switchover comparison (#208, #37).
#
# Prints a Markdown table with the app binary size, the Rust static archive size,
# per-segment totals for the binary, and the archive's exported symbol count.
# Appends the table to $GITHUB_STEP_SUMMARY when set, and always prints it to
# stdout. Also writes a machine-readable size-report.json next to the products.
#
# Usage:
#   Scripts/report-size.sh [--binary PATH] [--archive PATH] [--out-dir DIR]
#
# Defaults match Scripts/compile-release-aural.sh's release layout:
#   --binary   <repo>/.build/release/Aural
#   --archive  <repo>/Backend/lib/libaural_playback.a
#   --out-dir  <repo>

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

binary_path="$project_root/.build/release/Aural"
archive_path="$project_root/Backend/lib/libaural_playback.a"
out_dir="$project_root"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)
            binary_path="$2"
            shift 2
            ;;
        --archive)
            archive_path="$2"
            shift 2
            ;;
        --out-dir)
            out_dir="$2"
            shift 2
            ;;
        *)
            echo "report-size.sh: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ ! -f "$binary_path" ]]; then
    echo "report-size.sh: binary not found at $binary_path" >&2
    exit 1
fi

if [[ ! -f "$archive_path" ]]; then
    echo "report-size.sh: archive not found at $archive_path" >&2
    exit 1
fi

mkdir -p "$out_dir"

# --- byte sizes -------------------------------------------------------------

binary_bytes="$(stat -f %z "$binary_path")"
archive_bytes="$(stat -f %z "$archive_path")"

to_mib() {
    awk -v bytes="$1" 'BEGIN { printf "%.2f", bytes / (1024 * 1024) }'
}

binary_mib="$(to_mib "$binary_bytes")"
archive_mib="$(to_mib "$archive_bytes")"

# --- optional: segment sizes via `size -m` ---------------------------------

text_bytes=""
data_bytes=""
linkedit_bytes=""
have_size_tool=1

if command -v size >/dev/null 2>&1; then
    size_output="$(size -m "$binary_path" 2>/dev/null || true)"
    text_bytes="$(awk -F'[ \t]+' '/Segment __TEXT:/ { print $3; exit }' <<<"$size_output")"
    data_bytes="$(awk -F'[ \t]+' '/Segment __DATA:/ { print $3; exit }' <<<"$size_output")"
    linkedit_bytes="$(awk -F'[ \t]+' '/Segment __LINKEDIT:/ { print $3; exit }' <<<"$size_output")"
    if [[ -z "$text_bytes" || -z "$data_bytes" || -z "$linkedit_bytes" ]]; then
        have_size_tool=0
    fi
else
    have_size_tool=0
fi

# --- optional: exported symbol count via `nm -U` ----------------------------

symbol_count=""
have_nm_tool=1

if command -v nm >/dev/null 2>&1; then
    symbol_count="$(nm -U "$archive_path" 2>/dev/null | wc -l | awk '{print $1}')"
else
    have_nm_tool=0
fi

# --- render Markdown ---------------------------------------------------------

render_table() {
    echo "| Metric | Value |"
    echo "| --- | ---: |"
    echo "| App binary | ${binary_bytes} bytes (${binary_mib} MiB) |"
    echo "| libaural_playback.a | ${archive_bytes} bytes (${archive_mib} MiB) |"
    if [[ "$have_size_tool" -eq 1 ]]; then
        echo "| Binary __TEXT | ${text_bytes} bytes ($(to_mib "$text_bytes") MiB) |"
        echo "| Binary __DATA | ${data_bytes} bytes ($(to_mib "$data_bytes") MiB) |"
        echo "| Binary __LINKEDIT | ${linkedit_bytes} bytes ($(to_mib "$linkedit_bytes") MiB) |"
    else
        echo "| Binary segments | unavailable (\`size\` tool missing or unparseable) |"
    fi
    if [[ "$have_nm_tool" -eq 1 ]]; then
        echo "| Archive exported symbols | ${symbol_count} |"
    else
        echo "| Archive exported symbols | unavailable (\`nm\` tool missing) |"
    fi
}

table_heading="## Release build size"
table_body="$(render_table)"

print_report() {
    echo "$table_heading"
    echo
    echo "$table_body"
}

print_report

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    print_report >>"$GITHUB_STEP_SUMMARY"
fi

# --- write machine-readable JSON --------------------------------------------

json_path="$out_dir/size-report.json"

json_number_or_null() {
    if [[ -n "$1" ]]; then
        printf '%s' "$1"
    else
        printf 'null'
    fi
}

cat >"$json_path" <<JSON
{
  "binary_path": "$binary_path",
  "binary_bytes": $binary_bytes,
  "binary_mib": $binary_mib,
  "archive_path": "$archive_path",
  "archive_bytes": $archive_bytes,
  "archive_mib": $archive_mib,
  "binary_segments": {
    "available": $([[ "$have_size_tool" -eq 1 ]] && echo true || echo false),
    "text_bytes": $(json_number_or_null "$text_bytes"),
    "data_bytes": $(json_number_or_null "$data_bytes"),
    "linkedit_bytes": $(json_number_or_null "$linkedit_bytes")
  },
  "archive_exported_symbols": {
    "available": $([[ "$have_nm_tool" -eq 1 ]] && echo true || echo false),
    "count": $(json_number_or_null "$symbol_count")
  }
}
JSON

echo "Wrote $json_path"
