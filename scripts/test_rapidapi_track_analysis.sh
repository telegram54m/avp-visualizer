#!/usr/bin/env bash
# test_rapidapi_track_analysis.sh
#
# Empirical test of whether any RapidAPI "Track Analysis"-shaped service
# returns time-series audio data (beats, segments, chromagram over time)
# vs. only scalar metadata.
#
# Usage:
#   export RAPIDAPI_KEY="your-rapidapi-key"
#   # Optionally override these if you're testing a different API:
#   export RAPIDAPI_HOST="track-analysis.p.rapidapi.com"
#   export RAPIDAPI_PATH="/analyze"           # the endpoint path
#   export RAPIDAPI_TITLE_PARAM="title"       # query param name for song title
#   export RAPIDAPI_ARTIST_PARAM="artist"     # query param name for artist
#   ./test_rapidapi_track_analysis.sh
#
# Sign up at:  https://rapidapi.com/soundnet-soundnet-default/api/track-analysis
# After signing up, look at the "Code Snippets" → "(Shell) cURL" tab in
# the playground. Copy the exact host + path + param names into the env
# vars above. The free tier should be enough for the 5-track sample below.
#
# What this script verifies:
#   • The shape of the returned JSON (scalar vs. time-series)
#   • Whether ANY top-level key contains an array of more than 50 items
#     (which would be a time-series signal — beat array, segment array, etc.)
#   • The coverage across 5 tracks of varying age + popularity
#
# Output goes to ./rapidapi-output/<track>.json so you can inspect the
# raw response after the script finishes.

set -euo pipefail

if [[ -z "${RAPIDAPI_KEY:-}" ]]; then
  echo "error: RAPIDAPI_KEY env var not set"
  echo
  echo "1. sign up at https://rapidapi.com/soundnet-soundnet-default/api/track-analysis"
  echo "2. copy your X-RapidAPI-Key from the dashboard"
  echo "3. export RAPIDAPI_KEY=\"your-key\""
  echo "4. re-run this script"
  exit 1
fi

# Defaults assume SoundNet's Track Analysis API. Override via env vars
# above if testing a different listing.
HOST="${RAPIDAPI_HOST:-track-analysis.p.rapidapi.com}"
PATH_TPL="${RAPIDAPI_PATH:-/analyze}"
TITLE_PARAM="${RAPIDAPI_TITLE_PARAM:-title}"
ARTIST_PARAM="${RAPIDAPI_ARTIST_PARAM:-artist}"

# Test set: deliberately diverse coverage.
#   • Beatles (1969)            — well-indexed everywhere, baseline
#   • Aretha Franklin (1967)    — older, the article's own example
#   • Daft Punk Get Lucky (2013) — popular, recent enough
#   • Mitski Working for the Knife (2021) — modern, indie-ish
#   • Caroline Polachek Sunset (2023) — newer, art-pop, tests new releases
TRACKS=(
  "Because|The Beatles"
  "Respect|Aretha Franklin"
  "Get Lucky|Daft Punk"
  "Working for the Knife|Mitski"
  "Sunset|Caroline Polachek"
)

OUT_DIR="./rapidapi-output"
mkdir -p "$OUT_DIR"

printf "Testing %s with %d tracks\n\n" "$HOST" "${#TRACKS[@]}"

for track_spec in "${TRACKS[@]}"; do
  IFS='|' read -r title artist <<< "$track_spec"

  # URL-encode title + artist using jq (simpler than handling all the
  # edge cases manually in bash).
  enc_title=$(printf '%s' "$title" | jq -sRr @uri)
  enc_artist=$(printf '%s' "$artist" | jq -sRr @uri)

  url="https://${HOST}${PATH_TPL}?${TITLE_PARAM}=${enc_title}&${ARTIST_PARAM}=${enc_artist}"
  slug=$(printf '%s-%s' "$title" "$artist" | tr ' /' '__' | tr -cd 'A-Za-z0-9_-')
  out_file="${OUT_DIR}/${slug}.json"

  printf "→ %s — %s\n" "$title" "$artist"

  http_status=$(
    curl -sS -o "$out_file" -w '%{http_code}' \
      --connect-timeout 10 --max-time 30 \
      -H "x-rapidapi-key: ${RAPIDAPI_KEY}" \
      -H "x-rapidapi-host: ${HOST}" \
      "$url"
  )

  printf "    HTTP %s · %s\n" "$http_status" "$out_file"

  # Quick shape probe — does the response contain any large array?
  # >50 items at any path strongly suggests time-series data
  # (beats, segments, etc); scalar metadata APIs cap out at maybe a
  # dozen top-level scalar keys.
  if [[ "$http_status" == "200" ]]; then
    max_array_len=$(
      jq '[..|arrays|length] | max // 0' "$out_file" 2>/dev/null || echo "?"
    )
    top_keys=$(
      jq -r 'if type == "object" then keys|join(", ") else "[non-object]" end' \
        "$out_file" 2>/dev/null || echo "?"
    )
    printf "    top keys: %s\n" "$top_keys"
    printf "    longest array in response: %s items\n" "$max_array_len"
    if [[ "$max_array_len" =~ ^[0-9]+$ ]] && (( max_array_len > 50 )); then
      printf "    \033[32m✓ TIME-SERIES SIGNAL DETECTED — inspect %s\033[0m\n" "$out_file"
    else
      printf "    \033[33m✗ no large arrays — likely scalar metadata only\033[0m\n"
    fi
  fi

  printf "\n"

  # Be polite — many free tiers are 1-5 req/sec.
  sleep 1
done

echo "All responses saved to ${OUT_DIR}/. To inspect a specific track:"
echo "    jq . ${OUT_DIR}/Because-The_Beatles.json"
echo
echo "Verdict at a glance:"
echo "    grep -l 'TIME-SERIES' <(./test_rapidapi_track_analysis.sh)"
echo
echo "If ALL 5 tracks report 'no large arrays' the API is scalar-only and"
echo "won't help with the per-frame visualization gap. If even ONE returns"
echo "a >50-item array, inspect that response — could be the breakthrough."
