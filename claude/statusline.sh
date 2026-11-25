#!/bin/bash
# Pixel-Oktopus in doppelter Größe, rechts daneben eine Infospalte.
# Zustand aus /tmp/oktopus-<session_id> (von oktopus-hook.sh), Frame nach aktueller Sekunde,
# Farbe nach Kontextauslastung. Ein jq-Aufruf, ein zweiter nur bei neuen Nachrichten anderer Sitzungen.
# Texte auf Deutsch, wenn die bevorzugte Systemsprache Deutsch ist, sonst Englisch.
input=$(cat)

# Sprache aus den Systemeinstellungen, eine Stunde zwischengespeichert; OKTOPUS_SPRACHE=de|en überschreibt
sprache=$OKTOPUS_SPRACHE
if [[ -z $sprache ]]; then
  sf=/tmp/oktopus-sprache
  if [[ -n $(find "$sf" -mmin -60 2>/dev/null) ]]; then read -r sprache < "$sf"
  else
    [[ $(defaults read -g AppleLanguages 2>/dev/null | sed -n 2p) == *\"de* ]] && sprache=de || sprache=en
    printf '%s\n' "$sprache" > "$sf"
  fi
fi
[[ $sprache == de ]] && de=1 || de=
t() { if [[ -n $de ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
IFS=$'\x1f' read -r now sid modell name pct ctx h5 h5r d7 d7r cache cache_knapp arbeit ort tp < <(jq -r --arg de "$de" '
  def w(d; e): if $de == "1" then d else e end;
  def tage: w(["So","Mo","Di","Mi","Do","Fr","Sa"]; ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]);
  def uhr: localtime | strftime("%H:%M");
  def tag: localtime as $t | tage[$t[6]] + " " + ($t | strftime("%H:%M"));
  def geld: (. * 100 | round) as $c | "\($c / 100 | floor)\(w(","; "."))\($c % 100 | tostring | if length < 2 then "0" + . else . end)";
  def kurz: if . >= 1000000 then "\(. / 1000000 | floor)M" elif . >= 1000 then "\(. / 1000 | floor)k" else tostring end;
  (now | floor) as $now
  | .context_window as $c
  | ($c.current_usage // {}) as $u
  | (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0) + ($u.output_tokens // 0)) as $belegt
  | .rate_limits as $r
  | .prompt_cache as $p
  | [ $now,
      .session_id // "",
      (.model.display_name // "?") + (if .effort.level then w(" · Denkstufe "; " · effort ") + .effort.level else "" end),
      .session_name // "",
      ($c.used_percentage // "" | tostring),
      (if $c.context_window_size then "\($belegt | kurz) \(w("von"; "of")) \($c.context_window_size | kurz)" else "" end),
      ($r.five_hour.used_percentage // "" | tostring),
      ($r.five_hour.resets_at // null | if . then uhr else "" end),
      ($r.seven_day.used_percentage // "" | tostring),
      ($r.seven_day.resets_at // null | if . then tag else "" end),
      (if $p == null then "–"
       elif $p.warm then w("warm, noch "; "warm, ") + "\((($p.expires_at - $now) / 60) | floor) min" + w(""; " left") + " · \((($p.hit_ratio // 0) * 100) | floor) % " + w("Treffer"; "hits")
       else w("kalt"; "cold") end),
      (if $p.warm and ($p.expires_at - $now) < 300 then 1 else 0 end),
      "+\(.cost.total_lines_added // 0) −\(.cost.total_lines_removed // 0) \(w("Zeilen"; "lines")) · \(((.cost.total_duration_ms // 0) / 60000) | floor) min"
        + (if .cost.total_cost_usd then " · ≈ \(.cost.total_cost_usd | geld) $" else "" end),
      ((.workspace.current_dir // .cwd // "") | sub("^" + env.HOME; "~")),
      .transcript_path // ""
    ] | map(tostring) | join("\u001f")' <<< "$input")
# Eingabe für die Notch-App ablegen (nicht, wenn die App selbst zeichnen lässt)
[[ -z $OKTOPUS_APP && -n $sid ]] && printf '%s' "$input" > "/tmp/oktopus-$sid.json"
# Sitzungen in der tmux-Sitzung „rc“ markieren (mit tmux-Sitzungs-ID); die Notch-App zeigt sie bei Fernzugriff grün
[[ -z $OKTOPUS_APP && -n $sid && $TMUX == */rc,* ]] && printf '$%s' "${TMUX##*,}" > "/tmp/oktopus-$sid.rc"

# Gespräche mit anderen Sitzungen (SendMessage) aus dem Ende des Transkripts. Zeilen „Richtung<TAB>Zeit<TAB>Uhr<TAB>Name<TAB>Text“,
# zwischengespeichert in /tmp/oktopus-<sid>.post und nur neu gelesen, wenn sich das Transkript ändert.
post=
if [[ -z $OKTOPUS_APP && -z $OKTOPUS_JETZT && -n $sid && -r $tp ]]; then
  pf=/tmp/oktopus-$sid.post
  stempel=$(stat -f '%m %z' "$tp")
  alt=
  [[ -r $pf ]] && read -r alt < "$pf"
  if [[ $alt != "$stempel" ]]; then
    roh=$(tail -c 400000 "$tp" | grep -E 'cross-session-message|"SendMessage"')
    [[ -n $roh ]] && post=$(jq -R -s -r --arg u "$USER-" '
      def kurz: if startswith("uds:") then "?" else sub("^" + $u; "") end;
      [ split("\n")[] | fromjson? | select(.timestamp?) as $z
        | ($z.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdate) as $ts
        | if $z.type == "user" and ($z.message.content | type) == "string" and ($z.message.content | contains("<cross-session-message from=")) then
            $z.message.content | capture("<cross-session-message from=\"(?<peer>[^\"]*)\"(?: from-name=\"(?<name>[^\"]*)\")?[^>]*>\\s*(?<text>.*?)\\s*(</cross-session-message>|$)"; "s")
            | {d: "<", $ts, peer, name: (.name // .peer), text}
          elif $z.type == "assistant" then
            $z.message.content[]? | select(.type == "tool_use" and .name == "SendMessage" and (.input.message // "") != "")
            | {d: ">", $ts, peer: .input.to, name: .input.to, text: .input.message}
          else empty end ] | sort_by(.ts) as $r
      | ($r | map(select(.d == "<") | {(.peer): .name}) | add // {}) as $namen
      | $r[-4:][] | [.d, .ts, (.ts | localtime | strftime("%H:%M")), (($namen[.peer] // .name) | kurz), .text]
      | map(tostring | gsub("[\t\n\r ]+"; " ")) | join("\t")' <<< "$roh")
    printf '%s\n%s' "$stempel" "$post" > "$pf"
  else
    post=$(tail -n +2 "$pf")
  fi
fi
# Eben eingetroffene Nachricht: Oktopus schaut zur Seite, Briefblase
post_neu=0
if [[ -n $post ]]; then
  letzte=$(grep '^<' <<< "$post" | tail -1 | cut -f2)
  [[ -n $letzte ]] && (( now - letzte < 10 )) && post_neu=1
fi

# Fester Zeitpunkt für Vorschaubilder (scripts/gesten.swift)
[[ -n $OKTOPUS_JETZT ]] && now=$OKTOPUS_JETZT

f=/tmp/oktopus-$sid
state=wartet ts=$now extra=
[[ -n $sid && -r $f ]] && read -r state ts extra < "$f"
age=$(( now - ts ))

# Kurzlebige Zustände laufen in den Folgezustand über
case $state in
  hoert)   (( age > 2 )) && state=denkt ;;
  fehler)  (( age > 4 )) && state=denkt ;;
  spricht) (( age > 3 )) && state=denkt ;;
esac
(( age > 1800 )) && state=wartet

helfer=0
if [[ -n $sid && -d $f.helfer ]]; then
  h=("$f.helfer"/*)
  [[ -e ${h[0]} ]] && helfer=${#h[@]}
fi
[[ -n $OKTOPUS_HELFER ]] && helfer=$OKTOPUS_HELFER

[[ -n $OKTOPUS_ZUSTAND ]] && state=$OKTOPUS_ZUSTAND
s=$(( now % 60 )) t=$(( now % 2 )) w=$(( now / 2 % 2 ))
# Zufall pro Sekunde und pro 2-Sekunden-Takt, damit Blicke nicht im festen Raster kommen
streu() { local x=$(( ($1 * 2654435761) & 0xffffffff )); x=$(( (x ^ (x >> 15)) * 2246822519 & 0xffffffff )); zr=$(( (x ^ (x >> 13)) % 100 )); }
streu $now; z1=$zr
streu $(( now / 2 + 7 )); z2=$zr
links=0 rechts=0 zu=' '

# Große Augen als Pixel-Art: je 2×2 Zellen über zwei Gesichtszeilen (oben a, unten b).
auge() {
  case $1 in
    offen)  a='▗▄' b='▀▀' ;;
    hoch)   a='▟█' b='  ' ;;
    runter) a='  ' b='▟█' ;;
    gross)  a='▟█' b='▀▀' ;;
    halb)   a='▄▄' b='▀▀' ;;
    zu)     a='  ' b='▀▀' ;;
    froh)   a='▗▖' b='▘▝' ;;
    kreuz)  a='▚▞' b='▞▚' ;;
  esac
}
# Blick: Form beider Augen, optional rechtes Auge anders (Zwinkern); Richtung über Polster vl/vr
blick() { auge "$1"; la=$a lb=$b; auge "${2:-$1}"; ra=$a rb=$b; }
links_schauen()  { vl= vr='  '; }
rechts_schauen() { vl='  ' vr=; }

vl=' ' vr=' ' mund='‿'
blick offen
case $state in
  wartet)
    if   (( z1 < 12 )); then blick zu
    elif (( z2 < 15 )); then links_schauen
    elif (( z2 < 30 )); then rechts_schauen
    elif (( z2 < 40 )); then blick hoch
    elif (( z2 < 46 )); then blick runter
    elif (( z2 < 50 )); then blick offen froh
    fi
    was=$(t 'wartet auf dich' 'waiting for you') ;;
  hoert)
    blick gross; (( t )) || mund='o'; was=$(t 'hört zu' 'listening') ;;
  denkt)
    blick hoch; mund='-'
    (( z2 < 40 )) && links_schauen
    (( z2 >= 60 )) && rechts_schauen
    (( z1 < 8 )) && blick zu
    was=$(t 'denkt nach' 'thinking') ;;
  tool)
    mund='-'
    case $extra in
      Read|Grep|Glob|WebFetch|WebSearch|LSP)
        blick runter; (( t )) && links_schauen || rechts_schauen ;;
      Edit|Write|NotebookEdit)
        (( t )) && blick runter || blick halb ;;
      Bash)
        rechts_schauen; (( t )) && blick halb ;;
      Agent|Task*)
        blick hoch; (( t )) && blick gross ;;
      *)
        (( t )) && blick halb ;;
    esac
    was="▶ ${extra:-Tool}" ;;
  spricht)
    m3=('o' '‿' 'O'); mund=${m3[s % 3]}; (( s % 3 == 1 )) || zu=')'
    (( z1 < 10 )) && blick zu
    (( z2 < 15 )) && links_schauen
    was=$(t 'spricht' 'talking') ;;
  fragt)
    (( t )) && blick gross || mund='o'; (( t )) && rechts=1; was=$(t 'fragt um Erlaubnis' 'asking for permission') ;;
  fertig)
    (( t )) && blick froh || blick froh offen; links=1 rechts=1; was=$(t 'fertig' 'done') ;;
  fehler)
    (( t )) && blick kreuz || blick zu; mund='∩'; was=$(t 'Fehler' 'error') ;;
  schlaeft)
    blick zu; mund='-'; was=$(t 'schläft' 'asleep') ;;
  *)
    was=$(t 'wartet auf dich' 'waiting for you') ;;
esac
(( post_neu )) && [[ $state != fragt && $state != fehler ]] && rechts_schauen
augen_o="${vl}${la}   ${ra}${vr}" augen_u="${vl}${lb} ${mund} ${rb}${vr}"
(( helfer )) && was+=" · $helfer $(t Helfer helpers)"

p=${pct%%.*}
[[ $p == null ]] && p=
if [[ -z $p ]]; then c=255
elif (( p >= 90 )); then c=240
elif (( p >= 70 )); then c=248
else c=255
fi

E=$'\e[38;5;' R0=$'\e[0m'
C="${E}${c}m" G="${E}245m" D="${E}239m" W="${E}255m" T="${E}242m"

# Körper, jede Zeile 15 Zellen breit. Arme oben: Frage (rechts, winkt), Jubel (beide).
L='  ' R='  ' L2='  ' R2='  '
(( links )) && L='▐▌' L2='▐▙'
(( rechts )) && R='▐▌' R2='▟▌'
blase=$R
if (( post_neu && ! rechts )); then
  (( t )) && blase="${W}✉ $C" || blase="$G ✉$C"
elif [[ $state == denkt ]] && (( ! rechts )); then
  (( t )) && blase="${G}∘ $C" || blase="$G °$C"
elif [[ $state == schlaeft ]]; then
  (( t )) && blase="${G}z $C" || blase="$G Z$C"
fi
r1="$L ▄▄▄▄▄▄▄▄▄ $blase"
# Gesichtsfeld in Körperfarbe hinterlegt, Augen und Mund dunkel darauf
F=$'\e[48;5;'"${c}m"$'\e[38;5;16m'
r2="${L2}█${F}${augen_o}${R0}${C}█${R2}"
r3="  █${F}${augen_u}${R0}${C}█ $zu"
r4='  ▀█████████▀  '
# Unten: Arme schwingen, beim Tool greift der rechte nach außen, beim Fehler kommt Tinte
tinte='   ' tinte2='   '
if [[ $state == fehler ]]; then
  (( t )) && { tinte="${T}░▒ $C"; tinte2="${T}▒░▒$C"; } || { tinte="$T ░▒$C"; tinte2="${T}░▒░$C"; }
fi
# Helfer: kleiner grauer Oktopus links unten, solange Unteragenten laufen
if (( helfer )) && [[ $state != fehler ]]; then
  tinte="${G}▟█▙$C" tinte2="${G}▛▛▛$C"
  (( w )) && tinte2="${G}▜▜▜$C"
fi
if [[ $state == tool ]]; then
  (( t )) && r5="${tinte}▐▌▐▌ ▐▌▐▙▄▄▀" || r5="${tinte}▐▌▐▌ ▐▌▐▙▄▄▄"
  (( w )) && r6="${tinte2}▝▖▝▖ ▗▘     " || r6="${tinte2}▗▘▗▘ ▝▖     "
else
  r5="${tinte}▐▌▐▌ ▐▌▐▌   "
  (( w )) && r6="${tinte2}▝▖▝▖ ▗▘▗▘   " || r6="${tinte2}▗▘▗▘ ▝▖▝▖   "
fi

if [[ -n $p ]]; then
  n=$(( (p + 5) / 10 )) voll= leer=
  for (( i = 0; i < 10; i++ )); do
    if (( i < n )); then voll+='━'; else leer+='─'; fi
  done
  kontext="$W$voll$D$leer $G$p % · $ctx"
else
  kontext="${G}–"
fi

# Ab 80 % wird ein Limit weiß hervorgehoben
h5c=$G d7c=$G
[[ -n $h5 && $h5 != null ]] && (( ${h5%%.*} >= 80 )) && h5c=$W
[[ -n $d7 && $d7 != null ]] && (( ${d7%%.*} >= 80 )) && d7c=$W
bis=$(t bis until)
limits="${G}5 h $h5c${h5:-–} %$G $bis ${h5r:-–} · $(t Woche week) $d7c${d7:-–} %$G $bis ${d7r:-–}"
(( cache_knapp )) && cache="$W$cache" || cache="$G$cache"

if [[ -n $name ]]; then i1="$W$name" i2="$G$modell"; else i1="$W$modell" i2=; fi
i3="${D}$(t 'Kontext' 'Context') $kontext"
i4="${D}Limits  $limits"
i5="${D}Cache   $cache"
i6="${D}$(t 'Jetzt  ' 'Now    ') $G$was · $arbeit · $ort"

zeilen=("$i1" "$i2" "$i3" "$i4" "$i5" "$i6")

# Dritte Spalte: Gespräche der letzten 10 Minuten, nur wenn das Fenster breit genug ist.
# Die Breite kommt vom Terminal des aufrufenden claude-Prozesses.
spalte=()
if [[ -n $post ]]; then
  while IFS=$'\t' read -r d ts uhr wer text; do
    [[ -n $ts ]] && (( now - ts < 600 )) || continue
    [[ $d == '<' ]] && pfeil="${W}←" || pfeil="${G}→"
    spalte+=("$pfeil $W$wer $D$uhr $G$text")
  done <<< "$post"
fi
if (( ${#spalte[@]} )); then
  tty=$(ps -o tty= -p $PPID 2>/dev/null) tty=${tty// /}
  breite=${OKTOPUS_BREITE:-0}
  (( breite )) || [[ -z $tty || $tty == '??' ]] || read -r _ breite < <(stty -f "/dev/$tty" size 2>/dev/null)
  shopt -s extglob
  LC_ALL=en_US.UTF-8
  sichtbar() { local s=${1//$'\e'\[*([0-9;])m/}; n=${#s}; }
  lang=0
  for z in "${zeilen[@]}"; do sichtbar "$z"; (( n > lang )) && lang=$n; done
  # Oktopus 15 + 2 Abstand, Trenner 3, Rand 2
  platz=$(( ${breite:-0} - 17 - lang - 5 ))
  if (( platz >= 24 )); then
    for (( k = 0; k < ${#spalte[@]}; k++ )); do
      sichtbar "${zeilen[k]}"
      printf -v luecke '%*s' $(( lang - n )) ''
      s=${spalte[k]}
      sichtbar "$s"
      if (( n > platz )); then
        # Kürzen auf sichtbare Breite: Farbcodes stehen nur vor dem Text, der Text selbst ist schlicht
        vorn=${s% "$G"*} rest=${s##* "$G"}
        sichtbar "$vorn"
        rest=${rest:0:$(( platz - n - 2 ))}…
        s="$vorn $G$rest"
      fi
      zeilen[k]="${zeilen[k]}$luecke  ${D}┊ $s"
    done
  fi
fi

printf '%s%s%s  %s%s\n' "$C" "$r1" "$R0" "${zeilen[0]}" "$R0" "$C" "$r2" "$R0" "${zeilen[1]}" "$R0" "$C" "$r3" "$R0" "${zeilen[2]}" "$R0" \
  "$C" "$r4" "$R0" "${zeilen[3]}" "$R0" "$C" "$r5" "$R0" "${zeilen[4]}" "$R0" "$C" "$r6" "$R0" "${zeilen[5]}" "$R0"
