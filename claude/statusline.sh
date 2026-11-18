#!/bin/bash
# Pixel-Oktopus in doppelter Größe, rechts daneben eine Infospalte.
# Zustand aus /tmp/oktopus-<session_id> (von oktopus-hook.sh), Frame nach aktueller Sekunde,
# Farbe nach Kontextauslastung. Ein einziger jq-Aufruf, sonst nur Bash-Builtins.
input=$(cat)
IFS=$'\x1f' read -r now sid modell name pct ctx h5 h5r d7 d7r cache cache_knapp arbeit ort < <(jq -r '
  def tage: ["So","Mo","Di","Mi","Do","Fr","Sa"];
  def uhr: localtime | strftime("%H:%M");
  def tag: localtime as $t | tage[$t[6]] + " " + ($t | strftime("%H:%M"));
  def kurz: if . >= 1000000 then "\(. / 1000000 | floor)M" elif . >= 1000 then "\(. / 1000 | floor)k" else tostring end;
  (now | floor) as $now
  | .context_window as $c
  | ($c.current_usage // {}) as $u
  | (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0) + ($u.output_tokens // 0)) as $belegt
  | .rate_limits as $r
  | .prompt_cache as $p
  | [ $now,
      .session_id // "",
      (.model.display_name // "?") + (if .effort.level then " · Denkstufe " + .effort.level else "" end),
      .session_name // "",
      ($c.used_percentage // "" | tostring),
      (if $c.context_window_size then "\($belegt | kurz) von \($c.context_window_size | kurz)" else "" end),
      ($r.five_hour.used_percentage // "" | tostring),
      ($r.five_hour.resets_at // null | if . then uhr else "" end),
      ($r.seven_day.used_percentage // "" | tostring),
      ($r.seven_day.resets_at // null | if . then tag else "" end),
      (if $p == null then "–"
       elif $p.warm then "warm, noch \((($p.expires_at - $now) / 60) | floor) min · \((($p.hit_ratio // 0) * 100) | floor) % Treffer"
       else "kalt" end),
      (if $p.warm and ($p.expires_at - $now) < 300 then 1 else 0 end),
      "+\(.cost.total_lines_added // 0) −\(.cost.total_lines_removed // 0) Zeilen · \(((.cost.total_duration_ms // 0) / 60000) | floor) min",
      ((.workspace.current_dir // .cwd // "") | sub("^" + env.HOME; "~"))
    ] | map(tostring) | join("\u001f")' <<< "$input")
# Eingabe für die Notch-App ablegen (nicht, wenn die App selbst zeichnen lässt)
[[ -z $OKTOPUS_APP && -n $sid ]] && printf '%s' "$input" > "/tmp/oktopus-$sid.json"

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
    was='wartet auf dich' ;;
  hoert)
    blick gross; (( t )) || mund='o'; was='hört zu' ;;
  denkt)
    blick hoch; mund='-'
    (( z2 < 40 )) && links_schauen
    (( z2 >= 60 )) && rechts_schauen
    (( z1 < 8 )) && blick zu
    was='denkt nach' ;;
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
    was='spricht' ;;
  fragt)
    (( t )) && blick gross || mund='o'; rechts=1; was='fragt um Erlaubnis' ;;
  fertig)
    (( t )) && blick froh || blick froh offen; links=1 rechts=1; was='fertig' ;;
  fehler)
    (( t )) && blick kreuz || blick zu; mund='∩'; was='Fehler' ;;
  schlaeft)
    blick zu; mund='-'; was='schläft' ;;
  *)
    was='wartet auf dich' ;;
esac
augen_o="${vl}${la}   ${ra}${vr}" augen_u="${vl}${lb} ${mund} ${rb}${vr}"
(( helfer )) && links=1 && was+=" · $helfer Helfer"

p=${pct%%.*}
[[ $p == null ]] && p=
if [[ -z $p ]]; then c=255
elif (( p >= 90 )); then c=240
elif (( p >= 70 )); then c=248
else c=255
fi

E=$'\e[38;5;' R0=$'\e[0m'
C="${E}${c}m" G="${E}245m" D="${E}239m" W="${E}255m" T="${E}242m"

# Körper, jede Zeile 15 Zellen breit. Arme oben: Frage (rechts), Jubel (beide), Helfer (links).
L='  ' R='  ' L2='  ' R2='  '
(( links )) && L='▐▌' L2='▐▙'
(( rechts )) && R='▐▌' R2='▟▌'
blase=$R
if [[ $state == denkt ]] && (( ! rechts )); then
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
limits="${G}5 h $h5c${h5:-–} %$G bis ${h5r:-–} · Woche $d7c${d7:-–} %$G bis ${d7r:-–}"
(( cache_knapp )) && cache="$W$cache" || cache="$G$cache"

if [[ -n $name ]]; then i1="$W$name" i2="$G$modell"; else i1="$W$modell" i2=; fi
i3="${D}Kontext $kontext"
i4="${D}Limits  $limits"
i5="${D}Cache   $cache"
i6="${D}Jetzt   $G$was · $arbeit · $ort"

printf '%s%s%s  %s%s\n' "$C" "$r1" "$R0" "$i1" "$R0" "$C" "$r2" "$R0" "$i2" "$R0" "$C" "$r3" "$R0" "$i3" "$R0" \
  "$C" "$r4" "$R0" "$i4" "$R0" "$C" "$r5" "$R0" "$i5" "$R0" "$C" "$r6" "$R0" "$i6" "$R0"
