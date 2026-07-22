#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# translations.sh — Manage AppManager translation files
#
# Extracts translatable strings from Vala sources and AppStream metadata,
# regenerates the .pot template, merges it into every .po file, and validates
# each one with msgfmt.  Designed to work with the GLib / Meson i18n preset.
#
# Usage:
#   ./scripts/translations.sh              # full update + merge + stats
#   ./scripts/translations.sh --check-only # validate only, no changes
#   ./scripts/translations.sh --fix        # fix common errors (fuzzy broken entries)
#   ./scripts/translations.sh --export XX  # export untranslated strings → po/XX.yaml
#   ./scripts/translations.sh --import XX  # import translations from po/XX.yaml
#   ./scripts/translations.sh --help       # this message
#
# Dependencies: gettext (xgettext, msgmerge, msgfmt), python3, itstool (optional)
# ---------------------------------------------------------------------------

set -euo pipefail

# ---- helpers ---------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

msg()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC}   $*"; }
die()  { err "$*"; exit 1; }

# ---- paths & constants -----------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PO_DIR="$PROJECT_DIR/po"
POT_FILE="$PO_DIR/app-manager.pot"
LINGUAS_FILE="$PO_DIR/LINGUAS"
POTFILES_FILE="$PO_DIR/POTFILES"

# xgettext keywords matching GLib preset (Vala / C gettext conventions)
XGETTEXT_KEYWORDS=(
    --keyword=_
    --keyword=N_
    --keyword=Q_:1g
    --keyword=C_:1c,2
    --keyword=NC_:1c,2
    --keyword=ngettext:1,2
    --keyword=g_dngettext:2,3
)

# ---- argument parsing ------------------------------------------------------

CHECK_ONLY=false
FIX_MODE=false
SHOW_HELP=false
EXPORT_LANG=""
IMPORT_LANG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only) CHECK_ONLY=true ;;
        --fix)        FIX_MODE=true ;;
        --export)     EXPORT_LANG="$2"; shift ;;
        --import)     IMPORT_LANG="$2"; shift ;;
        --help|-h)    SHOW_HELP=true ;;
        *)            die "Unknown argument: $1" ;;
    esac
    shift
done

if $SHOW_HELP; then
    sed -n '2,/^$/p' "$0"
    exit 0
fi

# ---- export / import handlers -----------------------------------------------

if [[ -n "$EXPORT_LANG" ]]; then
    # Normalize: allow "lv" or "lv.po"
    LANG_CODE="${EXPORT_LANG%.po}"
    PO_FILE="$PO_DIR/${LANG_CODE}.po"
    YAML_FILE="$PO_DIR/${LANG_CODE}.yaml"

    [[ -f "$PO_FILE" ]] || die "file not found: $PO_FILE"

    msg "Exporting untranslated strings from ${LANG_CODE}.po → ${LANG_CODE}.yaml"

    python3 - "$PO_FILE" "$YAML_FILE" "$LANG_CODE" << 'PYEOF'
import sys, os, re
from datetime import datetime

po_file, yaml_file, lang = sys.argv[1:]

def parse_po(path):
    """Parse a .po file into a list of entries. Each entry is a dict with
    keys: comments, references, flags, msgid, msgstr, msgid_plural, msgstr_plurals."""
    with open(path, 'r', encoding='utf-8') as f:
        text = f.read()

    entries = []
    # Split on blank lines (entries are separated by one or more blank lines)
    blocks = re.split(r'\n\n+', text.strip())

    for block in blocks:
        lines = block.split('\n')
        entry = {'comments': [], 'references': [], 'flags': [],
                 'msgid': '', 'msgstr': '', 'msgid_plural': '', 'msgstr_plurals': []}
        current = None
        value_lines = []

        for line in lines:
            # Comment lines
            if line.startswith('#:'):
                # Extract all "file:line" tokens
                refs = re.findall(r'(\S+:\d+)', line)
                entry['references'].extend(refs)
                continue
            elif line.startswith('#,'):
                entry['flags'] = [f.strip() for f in line[2:].split(',')]
                continue
            elif line.startswith('#') and not line.startswith('#~'):
                entry['comments'].append(line)
                continue
            elif line.startswith('#~'):
                # Obsolete entries — skip
                current = None
                break

            # msgid / msgstr lines
            m = re.match(r'^(msgid|msgstr|msgid_plural)(?:\[(\d+)\])?\s+(.*)', line)
            if m:
                key = m.group(1)
                idx = m.group(2)
                val = m.group(3)

                # Flush previous key
                if current:
                    entry[current] = ''.join(value_lines)

                if key == 'msgid':
                    current = 'msgid'
                elif key == 'msgid_plural':
                    current = 'msgid_plural'
                elif key == 'msgstr':
                    if idx is not None:
                        # msgstr[N] — plural form
                        current = f'msgstr_{idx}'
                    else:
                        current = 'msgstr'

                value_lines = [val] if val else ['']
            elif line.startswith('"') and current:
                value_lines.append(line)

        # Flush last key
        if current:
            entry[current] = ''.join(value_lines)

        # Only keep entries that have a msgid (skip header)
        if entry['msgid']:
            entries.append(entry)

    return entries

def unescape_po(s):
    """Decode a PO string value: strip per-line quotes, join, unescape."""
    # s is the raw value from the .po file, e.g.:
    #   "line one "  or  "line one "\n"line two"
    # Split into individual quoted lines, strip the outer " from each,
    # then join and unescape.
    parts = []
    for part in re.findall(r'"(?:[^"\\]|\\.)*"', s):
        inner = part[1:-1]  # strip surrounding quotes
        parts.append(inner)
    result = ''.join(parts)
    result = result.replace('\\n', '\n')
    result = result.replace('\\t', '\t')
    result = result.replace('\\"', '"')
    result = result.replace('\\\\', '\\')
    return result

def escape_yaml_value(s):
    """Escape a string for YAML double-quoted value."""
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

entries = parse_po(po_file)

# Filter: only untranslated, non-fuzzy entries
untranslated = []
for e in entries:
    msgstr = unescape_po(e['msgstr'])
    if msgstr == '' and 'fuzzy' not in e['flags']:
        untranslated.append(e)

if not untranslated:
    print(f"No untranslated strings found in {po_file}")
    sys.exit(0)

# Build YAML
now = datetime.now().strftime('%Y-%m-%d %H:%M')
lines = []
lines.append(f"# Untranslated strings for {lang}.po — {now}")
lines.append(f"# Source: po/{lang}.po")
lines.append(f"#")
lines.append(f"# Fill in msgstr for each entry, then run:")
lines.append(f"#   ./scripts/translations.sh --import {lang}")
lines.append(f"#")
lines.append(f"entries:")

for e in untranslated:
    msgid = unescape_po(e['msgid'])
    lines.append(f"  - msgid: \"{escape_yaml_value(msgid)}\"")
    lines.append(f"    msgstr: \"\"")
    if e['references']:
        refs = ', '.join(e['references'])
        lines.append(f"    locations: \"{refs}\"")

with open(yaml_file, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')

print(f"Exported {len(untranslated)} untranslated strings → {yaml_file}")
PYEOF

    ok "Export complete: $YAML_FILE"
    exit 0
fi

if [[ -n "$IMPORT_LANG" ]]; then
    LANG_CODE="${IMPORT_LANG%.po}"
    PO_FILE="$PO_DIR/${LANG_CODE}.po"
    YAML_FILE="$PO_DIR/${LANG_CODE}.yaml"

    [[ -f "$PO_FILE" ]]  || die "file not found: $PO_FILE"
    [[ -f "$YAML_FILE" ]] || die "YAML not found: $YAML_FILE (run --export first)"

    # Pre-import validation
    msg "Validating ${LANG_CODE}.po before import…"
    PRE_ERR=$(msgfmt --check --check-accelerators="_" \
        --output-file=/dev/null "$PO_FILE" 2>&1) || true
    if [[ -n "$PRE_ERR" ]]; then
        err "Pre-import validation failed for ${LANG_CODE}.po:"
        echo "$PRE_ERR" | while IFS= read -r l; do echo -e "       ${RED}$l${NC}"; done
        die "Fix errors before importing. Try: ./scripts/translations.sh --fix"
    fi
    PRE_STATS=$(msgfmt --check --statistics --output-file=/dev/null "$PO_FILE" 2>&1) || true
    ok "Pre-import validation passed — $PRE_STATS"

    msg "Importing translations from ${LANG_CODE}.yaml → ${LANG_CODE}.po"

    python3 - "$PO_FILE" "$YAML_FILE" "$LANG_CODE" << 'PYEOF'
import sys, re

po_file, yaml_file, lang = sys.argv[1:]

def parse_yaml(path):
    """Parse the simple entries format produced by --export."""
    entries = []
    with open(path, 'r', encoding='utf-8') as f:
        text = f.read()

    # Find the first entry
    idx = text.find('\n  - msgid:')
    if idx == -1:
        idx = text.find('- msgid:')
    if idx == -1:
        print("No entries found in YAML file")
        return entries
    text = text[idx:]

    raw_entries = re.split(r'\n  - msgid:', text)
    for raw in raw_entries:
        if not raw.strip():
            continue
        if not raw.startswith('msgid:'):
            raw = 'msgid:' + raw

        m = re.search(r'msgid:\s*"(.*?)"', raw, re.DOTALL)
        if not m:
            continue
        msgid = m.group(1)
        msgid = msgid.replace('\\n', '\n').replace('\\t', '\t').replace('\\"', '"').replace('\\\\', '\\')

        m2 = re.search(r'msgstr:\s*"(.*?)"', raw, re.DOTALL)
        if not m2:
            continue
        msgstr = m2.group(1)
        msgstr = msgstr.replace('\\n', '\n').replace('\\t', '\t').replace('\\"', '"').replace('\\\\', '\\')

        if msgstr:
            entries.append({'msgid': msgid, 'msgstr': msgstr})

    return entries

def text_to_po_str(s):
    """Convert plain text into the exact PO quoted-string form."""
    escaped = s.replace('\\', '\\\\').replace('"', '\\"')
    lines = escaped.split('\n')
    if len(lines) == 1:
        return '"' + lines[0] + '"'
    parts = ['""']
    for line in lines:
        parts.append('"' + line + '\\n"')
    last = parts[-1]
    parts[-1] = last[:-3] + '"'
    return '\n'.join(parts)

yaml_entries = parse_yaml(yaml_file)

if not yaml_entries:
    print("No translations found in YAML file (all msgstr fields are empty)")
    sys.exit(1)

with open(po_file, 'r', encoding='utf-8') as f:
    po_text = f.read()

updated = 0
for ye in yaml_entries:
    # Build the msgid exactly as it appears in the .po file
    po_msgid = 'msgid ' + text_to_po_str(ye['msgid'])
    po_msgstr = 'msgstr ' + text_to_po_str(ye['msgstr'])

    # Find this msgid in the .po file
    pos = po_text.find(po_msgid)
    if pos == -1:
        print(f"  Warning: msgid not found: {ye['msgid'][:60]}...")
        continue

    # Find the msgstr that follows this msgid
    after_msgid = pos + len(po_msgid)
    tail = po_text[after_msgid:]
    m = re.search(r'msgstr\s+(""|"[^"]*")(?:\s*\n(?:"[^"]*"))*', tail)
    if not m:
        print(f"  Warning: no msgstr after msgid at position {pos}")
        continue

    old_msgstr = m.group(0)
    new_tail = tail.replace(old_msgstr, po_msgstr, 1)
    po_text = po_text[:after_msgid] + new_tail
    updated += 1

# Write back
with open(po_file, 'w', encoding='utf-8') as f:
    f.write(po_text)

print(f"Imported {updated} translation(s) into {po_file}")
PYEOF

    IMPORT_RESULT=$?
    if [[ $IMPORT_RESULT -ne 0 ]]; then
        die "Import failed."
    fi

    # Post-import validation
    msg "Validating ${LANG_CODE}.po after import…"
    POST_ERR=$(msgfmt --check --check-accelerators="_" \
        --output-file=/dev/null "$PO_FILE" 2>&1) || true
    POST_STATS=$(msgfmt --check --statistics --output-file=/dev/null "$PO_FILE" 2>&1) || true

    if [[ -n "$POST_ERR" ]]; then
        err "Post-import validation found errors:"
        echo "$POST_ERR" | while IFS= read -r l; do echo -e "       ${RED}$l${NC}"; done
        warn "You may need to fix format specifiers manually."
    else
        ok "Post-import validation passed — $POST_STATS"
    fi

    exit 0
fi

# ---- pre-flight checks -----------------------------------------------------

msg "Checking required tools..."

for tool in xgettext msgmerge msgfmt; do
    command -v "$tool" &>/dev/null || die "'$tool' not found — install gettext package"
done
ok "xgettext, msgmerge, msgfmt found"

# itstool is needed for extracting strings from .metainfo.xml
if command -v itstool &>/dev/null; then
    ok "itstool found (AppStream / XML support)"
    HAVE_ITSTOOL=true
else
    warn "itstool not found — AppStream strings will be skipped"
    warn "Install 'itstool' to include metainfo translations"
    HAVE_ITSTOOL=false
fi

# ---- step 1: collect source files from POTFILES ----------------------------

msg "Reading POTFILES…"
SRC_FILES=()
XML_FILES=()

if [[ ! -f "$POTFILES_FILE" ]]; then
    die "POTFILES not found at $POTFILES_FILE"
fi

while IFS= read -r line; do
    # skip comments and blank lines
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == *.xml ]]; then
        XML_FILES+=("$PROJECT_DIR/$line")
    else
        # Store relative paths — xgettext resolves them via --directory
        SRC_FILES+=("$line")
    fi
done < "$POTFILES_FILE"

msg "Found ${#SRC_FILES[@]} source files, ${#XML_FILES[@]} XML files"

# ---- step 2: extract strings → .pot ----------------------------------------

if $CHECK_ONLY; then
    msg "Skipping .pot regeneration (--check-only)"
else
    msg "Extracting translatable strings…"

    # 2a. Source files (Vala)
    if [[ ${#SRC_FILES[@]} -gt 0 ]]; then
        # Build a temp file list with paths relative to project root so
        # xgettext emits clean "#: src/foo.vala:NN" references.
        SRC_LIST=$(mktemp)
        for f in "${SRC_FILES[@]}"; do
            printf '%s\n' "$f"
        done > "$SRC_LIST"

        xgettext \
            --language=C \
            --from-code=UTF-8 \
            --package-name=app-manager \
            --package-version=1.0 \
            --msgid-bugs-address='' \
            --add-comments='TRANSLATORS:' \
            "${XGETTEXT_KEYWORDS[@]}" \
            --directory="$PROJECT_DIR" \
            --files-from="$SRC_LIST" \
            --output="$POT_FILE.tmp"

        rm -f "$SRC_LIST"
        ok "Source strings extracted"
    else
        warn "No source files listed in POTFILES"
        # Create minimal empty pot
        touch "$POT_FILE.tmp"
    fi

    # 2b. XML files (AppStream metainfo via itstool)
    if $HAVE_ITSTOOL && [[ ${#XML_FILES[@]} -gt 0 ]]; then
        XML_POT=$(mktemp)
        for xmlf in "${XML_FILES[@]}"; do
            if [[ -f "$xmlf" ]]; then
                # itstool extracts <_p>, <_li>, <_title>, etc. and the
                # standard AppStream <name>, <summary>, <description> tags.
                itstool \
                    --output="$XML_POT.tmp" \
                    "$xmlf" 2>/dev/null || true
                if [[ -f "$XML_POT.tmp" ]]; then
                    cat "$XML_POT.tmp" >> "$XML_POT"
                    rm -f "$XML_POT.tmp"
                fi
            fi
        done

        if [[ -s "$XML_POT" ]]; then
            # Strip absolute paths so references are relative (like xgettext output)
            sed -i "s|#: $PROJECT_DIR/|#: |g" "$XML_POT"
            # Merge XML pot into the main pot
            msgcat --use-first "$POT_FILE.tmp" "$XML_POT" -o "$POT_FILE.tmp.merged"
            mv "$POT_FILE.tmp.merged" "$POT_FILE.tmp"
            ok "XML (AppStream) strings extracted"
        fi
        rm -f "$XML_POT"
    fi

    # 2c. Replace date stamp and move into place
    if [[ -f "$POT_FILE.tmp" ]]; then
        # Update POT-Creation-Date to now
        NOW=$(date +"%Y-%m-%d %H:%M%z")
        sed -i "s/^\"POT-Creation-Date: .*$/\"POT-Creation-Date: $NOW\\\\n\"/" "$POT_FILE.tmp"
        mv "$POT_FILE.tmp" "$POT_FILE"
        ok ".pot template updated → $POT_FILE"
    else
        die "Failed to generate .pot file"
    fi
fi

# ---- step 3: read language list ---------------------------------------------

if [[ ! -f "$LINGUAS_FILE" ]]; then
    die "LINGUAS file not found at $LINGUAS_FILE"
fi

LANGS=()
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    LANGS+=("$line")
done < "$LINGUAS_FILE"

msg "Languages to process: ${#LANGS[@]} (${LANGS[*]})"

# ---- fix helpers ------------------------------------------------------------

# fix_po_errors <file.po> <msgfmt-stderr>
#
# Parses msgfmt error output and marks offending entries as fuzzy so the
# original (English) string is used until a human fixes the translation.
# Currently handles:
#   - "number of format specifications … does not match"
fix_po_errors() {
    local po_file="$1"
    local err_output="$2"
    local fixed=0

    # Extract line numbers from format-spec mismatch errors
    # msgfmt output: "file.po:212: number of format specifications in 'msgid'..."
    local -a bad_lines=()
    while IFS= read -r eline; do
        if [[ "$eline" =~ :([0-9]+):.*format\ specifications ]]; then
            bad_lines+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$err_output"

    if [[ ${#bad_lines[@]} -eq 0 ]]; then
        echo "0"
        return 0
    fi

    msg "  [fix] marking ${#bad_lines[@]} broken entries as fuzzy…" >&2

    # Build a set of msgid-start lines that contain the reported line numbers.
    # A .po entry starts with a line that is either 'msgid' or a comment/flag
    # line immediately before 'msgid'.  We walk backward from each bad line to
    # find the msgid line, then go back further to find the entry boundary.
    local -A msgid_lines=()  # line-number → 1

    while IFS= read -r bad_ln; do
        # Walk backwards to find the msgid line for this entry
        local seek=$bad_ln
        while (( seek > 0 )); do
            local line_content
            line_content=$(sed -n "${seek}p" "$po_file")
            if [[ "$line_content" == msgid* ]]; then
                msgid_lines[$seek]=1
                break
            fi
            ((seek--)) || true
        done
    done < <(printf '%s\n' "${bad_lines[@]}")

    # Now mark each entry fuzzy: find the line just before msgid.
    # If it already has "#, fuzzy", skip. Otherwise insert "#, fuzzy" there.
    # We process in reverse line order so line numbers stay stable.
    local -a sorted_msgids=()
    for ln in "${!msgid_lines[@]}"; do
        sorted_msgids+=("$ln")
    done
    # Sort descending
    readarray -t sorted_msgids < <(printf '%s\n' "${sorted_msgids[@]}" | sort -rn)

    for msgl in "${sorted_msgids[@]}"; do
        local prev=$((msgl - 1))
        local prev_content
        prev_content=$(sed -n "${prev}p" "$po_file")

        # Check if already fuzzy
        if [[ "$prev_content" == "#, fuzzy" ]]; then
            continue
        fi

        # Insert "#, fuzzy" before msgid
        sed -i "${msgl}i #, fuzzy" "$po_file"
        ((fixed++)) || true
    done

    echo "$fixed"
}

# ---- step 4: merge .pot → .po  +  validate ---------------------------------

TOTAL_PO=0
PASSED=0
FAILED=0
FIXED_TOTAL=0
declare -A STATS

for lang in "${LANGS[@]}"; do
    PO_FILE="$PO_DIR/${lang}.po"

    if $CHECK_ONLY; then
        if [[ ! -f "$PO_FILE" ]]; then
            warn "[$lang] missing .po file — skipped"
            continue
        fi
    else
        if [[ ! -f "$PO_FILE" ]]; then
            msg "[$lang] creating new .po from template…"
            msginit \
                --no-translator \
                --locale="$lang" \
                --input="$POT_FILE" \
                --output="$PO_FILE" 2>/dev/null || {
                    warn "[$lang] msginit failed — skipping"
                    continue
                }
        else
            msg "[$lang] merging .pot → .po…"
            msgmerge \
                --backup=none \
                --update \
                --quiet \
                --no-fuzzy-matching \
                "$PO_FILE" \
                "$POT_FILE" || {
                    warn "[$lang] msgmerge failed"
                    ((FAILED++)) || true
                    continue
                }
        fi
    fi

    TOTAL_PO=$((TOTAL_PO + 1))

    # ---- validation with msgfmt --------------------------------------------
    # --check              : verify format strings, plural forms
    # --check-accelerators : catch missing underscore accelerators
    # --statistics         : emit counts
    STATS_OUT=$(msgfmt \
        --check \
        --check-accelerators="_" \
        --statistics \
        --output-file=/dev/null \
        "$PO_FILE" 2>&1) || true

    ERR_OUT=$(msgfmt \
        --check \
        --check-accelerators="_" \
        --output-file=/dev/null \
        "$PO_FILE" 2>&1) || true

    if [[ -z "$ERR_OUT" ]]; then
        ok "[$lang] valid — $STATS_OUT"
        PASSED=$((PASSED + 1))
    else
        # Fatal errors from msgfmt → use err severity
        err "[$lang] has fatal errors — $STATS_OUT"
        while IFS= read -r eline; do
            echo -e "       ${RED}$eline${NC}"
        done <<< "$ERR_OUT"

        if $FIX_MODE; then
            FIXED=$(fix_po_errors "$PO_FILE" "$ERR_OUT")
            if [[ "$FIXED" -gt 0 ]]; then
                ok "  [fix] marked $FIXED entries as fuzzy"
                FIXED_TOTAL=$((FIXED_TOTAL + FIXED))
                # Re-validate after fixing
                RE_ERR=$(msgfmt \
                    --check \
                    --check-accelerators="_" \
                    --output-file=/dev/null \
                    "$PO_FILE" 2>&1) || true
                if [[ -z "$RE_ERR" ]]; then
                    ok "  [fix] re-validation passed"
                    PASSED=$((PASSED + 1))
                    # Update stats after fix
                    STATS_OUT=$(msgfmt \
                        --check \
                        --check-accelerators="_" \
                        --statistics \
                        --output-file=/dev/null \
                        "$PO_FILE" 2>&1) || true
                else
                    err "  [fix] errors remain after fixing:"
                    while IFS= read -r eline; do
                        echo -e "         ${RED}$eline${NC}"
                    done <<< "$RE_ERR"
                    FAILED=$((FAILED + 1))
                fi
            else
                warn "  [fix] no automatically fixable errors found"
                FAILED=$((FAILED + 1))
            fi
        else
            FAILED=$((FAILED + 1))
        fi
    fi

    STATS["$lang"]="$STATS_OUT"
done

# ---- step 5: summary -------------------------------------------------------

echo ""
echo -e "${BOLD}==========================${NC}"
echo -e "${BOLD}  Translation Summary${NC}"
echo -e "${BOLD}==========================${NC}"
echo -e "  Total languages : ${CYAN}$TOTAL_PO${NC}"
echo -e "  Valid           : ${GREEN}$PASSED${NC}"
if [[ $FAILED -gt 0 ]]; then
    echo -e "  With errors     : ${RED}$FAILED${NC}"
else
    echo -e "  With errors     : 0"
fi
if $FIX_MODE && [[ $FIXED_TOTAL -gt 0 ]]; then
    echo -e "  Entries fixed   : ${YELLOW}$FIXED_TOTAL${NC} (marked fuzzy)"
fi
echo ""

# Print per-language stats table
printf "  %-6s %-22s %s\n" "Code" "Language" "Statistics"
printf "  %-6s %-22s %s\n" "----" "----------------------" "----------"

# Language names lookup (ISO 639-1)
declare -A LANG_NAMES=(
    [ar]="Arabic"
    [de]="German"
    [el]="Greek"
    [es]="Spanish"
    [et]="Estonian"
    [fi]="Finnish"
    [fr]="French"
    [ga]="Irish"
    [it]="Italian"
    [ja]="Japanese"
    [kk]="Kazakh"
    [ko]="Korean"
    [lt]="Lithuanian"
    [lv]="Latvian"
    [nb]="Norwegian Bokmål"
    [nl]="Dutch"
    [pl]="Polish"
    [pt_BR]="Portuguese (Brazil)"
    [sv]="Swedish"
    [uk]="Ukrainian"
    [vi]="Vietnamese"
    [zh_CN]="Chinese (Simplified)"
)

for lang in "${LANGS[@]}"; do
    name="${LANG_NAMES[$lang]:-$lang}"
    s="${STATS[$lang]:-N/A}"
    printf "  %-6s %-22s %s\n" "$lang" "$name" "$s"
done

echo ""

if [[ $FAILED -gt 0 ]]; then
    warn "Some .po files have integrity issues — review warnings above"
    exit 1
else
    ok "All translation files passed validation"
    exit 0
fi
