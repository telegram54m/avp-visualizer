#!/usr/bin/env bash
# probe_ab_tier2_coverage.sh
#
# Pre-validates AcousticBrainz Tier 2 coverage for a curated list of
# pre-2018 canonical tracks BEFORE we spend time playing them on the
# iPhone. For each (title, artist):
#   1. MusicBrainz `/recording/?query=...` → up to 5 MBIDs in score order
#   2. AcousticBrainz `/low-level` for each MBID, stop at first 200
#   3. Classify outcome:
#        TIER2  — AB returned beats_position with >= 8 entries
#        BPM    — AB returned bpm but no usable beats_position
#        NO_AB  — all MBIDs returned 404 / no data
#        NO_MB  — MusicBrainz search returned 0 recordings
#        TIMEOUT — all attempts timed out (AB structurally degraded)
#        ERROR  — network / JSON failure
#
# Mirrors the chain in MusicBrainzBpmFetcher.swift so results predict
# what the iOS app will see for the same titles. Uses 25s AB timeout
# matching the app.
#
# Usage:
#   ./probe_ab_tier2_coverage.sh                 # uses built-in list
#   ./probe_ab_tier2_coverage.sh tracks.tsv      # title<TAB>artist per line
#   ./probe_ab_tier2_coverage.sh - <<EOF         # read from stdin
#   Yesterday	The Beatles
#   EOF

set -u

UA="HighVidelity/0.1 (https://telegram54m.github.io/avp-visualizer)"
AB_TIMEOUT=25
MB_TIMEOUT=12

# Curated canonical pre-2018 catalog spanning genres / decades / labels.
# Bias: tracks AB was likely to have analyzed during its 2015-2018
# fingerprint sweep. Beatles + Stones + classic rock + 80s pop +
# 90s alternative + 2000s singles. Avoids covers / remixes / live
# versions where the MBID match might land on the wrong recording.
read -r -d '' DEFAULT_TRACKS <<'EOF'
Yesterday	The Beatles
Hey Jude	The Beatles
Let It Be	The Beatles
Come Together	The Beatles
Paint It, Black	The Rolling Stones
(I Can't Get No) Satisfaction	The Rolling Stones
Stairway to Heaven	Led Zeppelin
Hotel California	Eagles
Bohemian Rhapsody	Queen
Another Brick in the Wall, Part 2	Pink Floyd
Sweet Child o' Mine	Guns N' Roses
Smells Like Teen Spirit	Nirvana
Wonderwall	Oasis
Creep	Radiohead
Karma Police	Radiohead
Seven Nation Army	The White Stripes
Take On Me	a-ha
Billie Jean	Michael Jackson
Thriller	Michael Jackson
Like a Prayer	Madonna
Lose Yourself	Eminem
In da Club	50 Cent
Crazy in Love	Beyoncé
Umbrella	Rihanna
Rolling in the Deep	Adele
Somebody That I Used to Know	Gotye
Get Lucky	Daft Punk
Uptown Funk	Mark Ronson
Shape of You	Ed Sheeran
EOF

# --- helpers ---------------------------------------------------------

# Lucene-escape special chars used in MB queries. Mirrors the Swift
# implementation's reserved set. Pure bash so we don't fight BSD sed's
# character-class parsing.
lucene_escape() {
    local s="$1" out="" ch
    local i=0 n=${#s}
    while (( i < n )); do
        ch=${s:$i:1}
        case "$ch" in
            '+'|'-'|'&'|'|'|'!'|'('|')'|'{'|'}'|'['|']'|'^'|'"'|'~'|'*'|'?'|':'|'\\'|'/')
                out+='\'"$ch"
                ;;
            *)
                out+="$ch"
                ;;
        esac
        i=$((i+1))
    done
    printf '%s' "$out"
}

# MusicBrainz recording search. stdout: newline-separated MBIDs (best-
# scoring first), up to 5. Empty output = no match. Returns 0 on
# success, 1 on network / HTTP error.
mb_search() {
    local title="$1" artist="$2"
    local et ea
    et=$(lucene_escape "$title")
    ea=$(lucene_escape "$artist")
    local query="recording:\"$et\" AND artist:\"$ea\""
    # url-encode the query via curl --data-urlencode + -G
    local body http
    body=$(curl -sS -G \
        --connect-timeout 8 --max-time "$MB_TIMEOUT" \
        -H "User-Agent: $UA" -H "Accept: application/json" \
        --data-urlencode "query=$query" \
        --data-urlencode "fmt=json" \
        --data-urlencode "limit=5" \
        -w "\n__HTTP__%{http_code}" \
        "https://musicbrainz.org/ws/2/recording/" 2>/dev/null) || return 1
    http=$(printf '%s' "$body" | sed -n 's/^__HTTP__//p' | tail -1)
    body=$(printf '%s' "$body" | sed '$d')
    [[ "$http" == "200" ]] || return 1
    printf '%s' "$body" | jq -r '.recordings[]?.id' 2>/dev/null
}

# AcousticBrainz low-level fetch for one MBID.
# stdout: "<bpm>\t<beat_count>" if 200 with bpm; empty otherwise.
# return code:
#   0  got data (may still be no-beats)
#   2  404 / no analysis
#   3  timeout
#   4  other error
ab_low() {
    local mbid="$1"
    local body http rc
    body=$(curl -sS \
        --connect-timeout 8 --max-time "$AB_TIMEOUT" \
        -H "Accept: application/json" \
        -w "\n__HTTP__%{http_code}" \
        "https://acousticbrainz.org/api/v1/$mbid/low-level" 2>/dev/null)
    rc=$?
    if [[ $rc -eq 28 ]]; then  # curl timeout
        return 3
    elif [[ $rc -ne 0 ]]; then
        return 4
    fi
    http=$(printf '%s' "$body" | sed -n 's/^__HTTP__//p' | tail -1)
    body=$(printf '%s' "$body" | sed '$d')
    if [[ "$http" == "404" ]]; then return 2; fi
    [[ "$http" == "200" ]] || return 4
    # Parse bpm + beats_position length. jq tolerates missing fields.
    local parsed
    parsed=$(printf '%s' "$body" | jq -r '
        (.rhythm.bpm // empty) as $bpm |
        ((.rhythm.beats_position // []) | length) as $n |
        if $bpm then "\($bpm)\t\($n)" else empty end
    ' 2>/dev/null)
    [[ -n "$parsed" ]] || return 4
    printf '%s' "$parsed"
}

# --- main loop -------------------------------------------------------

# Pick input source.
if [[ $# -eq 0 ]]; then
    INPUT=$DEFAULT_TRACKS
elif [[ "$1" == "-" ]]; then
    INPUT=$(cat)
else
    [[ -f "$1" ]] || { echo "no such file: $1" >&2; exit 1; }
    INPUT=$(cat "$1")
fi

# Counters
TOT=0; T2=0; BPM=0; NOAB=0; NOMB=0; TIM=0; ERR=0

# Pretty header
printf '%-40s %-25s %-8s %s\n' "TITLE" "ARTIST" "OUTCOME" "DETAIL"
printf '%-40s %-25s %-8s %s\n' "-----" "------" "-------" "------"

while IFS=$'\t' read -r title artist; do
    [[ -z "${title// }" ]] && continue
    [[ "$title" =~ ^# ]] && continue
    TOT=$((TOT+1))

    title_trunc=${title:0:40}
    artist_trunc=${artist:0:25}

    # MB lookup
    mbids=$(mb_search "$title" "$artist") || {
        printf '%-40s %-25s %-8s %s\n' "$title_trunc" "$artist_trunc" "ERROR" "MB search failed"
        ERR=$((ERR+1))
        sleep 1.1  # MB rate limit (1 req/sec per their AUP)
        continue
    }
    if [[ -z "$mbids" ]]; then
        printf '%-40s %-25s %-8s %s\n' "$title_trunc" "$artist_trunc" "NO_MB" "0 MBIDs"
        NOMB=$((NOMB+1))
        sleep 1.1
        continue
    fi

    # Walk MBIDs until one has AB data, or we exhaust the list.
    outcome="NO_AB"
    detail=""
    timeouts=0
    nonHits=0
    mbid_used=""
    while IFS= read -r mbid; do
        [[ -z "$mbid" ]] && continue
        if result=$(ab_low "$mbid"); then
            bpm=$(printf '%s' "$result" | cut -f1)
            beats=$(printf '%s' "$result" | cut -f2)
            mbid_used="$mbid"
            if [[ "$beats" -ge 8 ]]; then
                outcome="TIER2"
                detail="bpm=$bpm beats=$beats mbid=${mbid:0:8}"
                T2=$((T2+1))
            else
                outcome="BPM"
                detail="bpm=$bpm beats=$beats mbid=${mbid:0:8}"
                BPM=$((BPM+1))
            fi
            break
        else
            rc=$?
            case $rc in
                2) nonHits=$((nonHits+1));;
                3) timeouts=$((timeouts+1));;
                *) nonHits=$((nonHits+1));;
            esac
        fi
    done <<<"$mbids"

    if [[ -z "$mbid_used" ]]; then
        if [[ $timeouts -gt 0 && $nonHits -eq 0 ]]; then
            outcome="TIMEOUT"
            detail="all $timeouts MBIDs timed out (${AB_TIMEOUT}s each)"
            TIM=$((TIM+1))
        else
            mb_total=$(printf '%s\n' "$mbids" | grep -c .)
            detail="$mb_total MBIDs tried, $timeouts timed out, $nonHits no-data"
            NOAB=$((NOAB+1))
        fi
    fi

    printf '%-40s %-25s %-8s %s\n' "$title_trunc" "$artist_trunc" "$outcome" "$detail"

    # MB AUP: 1 req/sec average. AB is more permissive but pace anyway.
    sleep 1.1
done <<<"$INPUT"

# Summary
echo
echo "--- summary ($TOT tracks) ---"
printf 'TIER2 (beats >= 8): %d  (%d%%)\n' "$T2" "$(( TOT > 0 ? T2*100/TOT : 0 ))"
printf 'BPM only:           %d  (%d%%)\n' "$BPM" "$(( TOT > 0 ? BPM*100/TOT : 0 ))"
printf 'No AB data:         %d  (%d%%)\n' "$NOAB" "$(( TOT > 0 ? NOAB*100/TOT : 0 ))"
printf 'AB all timed out:   %d  (%d%%)\n' "$TIM" "$(( TOT > 0 ? TIM*100/TOT : 0 ))"
printf 'No MB match:        %d  (%d%%)\n' "$NOMB" "$(( TOT > 0 ? NOMB*100/TOT : 0 ))"
printf 'Errors:             %d\n' "$ERR"
echo
echo "TIER2 tracks are the candidates to test on iPhone — they SHOULD"
echo "promote from Tier 3 to Tier 2 if the iOS chain is healthy."
