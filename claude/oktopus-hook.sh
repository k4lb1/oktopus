#!/bin/bash
# Schreibt den Oktopus-Zustand für die Statuszeile: oktopus-hook.sh <zustand>
# Liest die Hook-Eingabe von stdin; kein jq, damit es bei jedem Tool schnell bleibt.
in=$(cat)
[[ $in =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] || exit 0
f="/tmp/oktopus-${BASH_REMATCH[1]}"
case $1 in
  ende)
    rm -rf "$f" "$f.helfer" "$f.json" ;;
  helfer+|helfer-)
    [[ $in =~ \"agent_id\"[[:space:]]*:[[:space:]]*\"([^\"/]+)\" ]] || exit 0
    if [[ $1 == helfer+ ]]; then
      mkdir -p "$f.helfer" && : > "$f.helfer/${BASH_REMATCH[1]}"
    else
      rm -f "$f.helfer/${BASH_REMATCH[1]}"
    fi ;;
  *)
    extra=
    [[ $in =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && extra=${BASH_REMATCH[1]##*__}
    printf '%s %s %s\n' "$1" "$(date +%s)" "$extra" > "$f" ;;
esac
exit 0
