#!/usr/bin/env bash
#
# board-agent.sh — otomatisasi AI Board -> OpenCode.
#
# Polling board tiap tick; pesan baru dari manusia (bukan sender bot)
# dikumpulkan sebentar (batching), lalu script:
#   1. ambil konteks N pesan terakhir di board,
#   2. susun prompt (konteks + pesan baru),
#   3. jalankan `opencode run` (engine agent OpenCode, punya akses tools),
#   4. post jawaban agent balik ke board sebagai "Re: #<id>" (sender bot).
#
# Anti-loop: pesan dari sender bot di-skip, jadi reply bot ga memicu bot lagi.
#
# Usage:
#   ./scripts/board-agent.sh --once     # satu tick, buat cron / systemd timer
#   ./scripts/board-agent.sh            # mode daemon, polling tiap POLL_INTERVAL
#
# Config (env, bisa ditaruh di .env di root repo):
#   AI_BOARD_URL            default https://ai-board-azure.vercel.app/api/messages
#   AI_BOARD_BOT_SENDER     default opencode (sender bot; di-skip dari trigger)
#   AI_BOARD_MODEL          default kosong = ikut config opencode.json.
#                           Contoh model gratis: "ollama/qwen2.5-coder"
#                           (Ollama lokal) atau OpenRouter dengan suffix ":free".
#                           Cek daftar: opencode models / opencode run --help
#   AI_BOARD_POLL_INTERVAL  detik antar poll saat mode daemon (default 60)
#   AI_BOARD_BATCH_WINDOW   detik nunggu pesan tambahan sebelum diproses (default 20)
#   AI_BOARD_COOLDOWN       detik minimal antar pemanggilan agent (default 120)
#   AI_BOARD_CONTEXT_COUNT  jumlah pesan konteks yang di-inject (default 20)
#   AI_BOARD_REPLY_MAX_LEN  maks karakter jawaban yang dipost (default 1500)
#   AI_BOARD_STATE_FILE     default ~/.cache/ai-board/last-id

set -euo pipefail

# --- config ---
BOARD_URL="${AI_BOARD_URL:-https://ai-board-azure.vercel.app/api/messages}"
BOT_SENDER="${AI_BOARD_BOT_SENDER:-opencode}"
MODEL="${AI_BOARD_MODEL:-}"
POLL_INTERVAL="${AI_BOARD_POLL_INTERVAL:-60}"
BATCH_WINDOW="${AI_BOARD_BATCH_WINDOW:-20}"
COOLDOWN="${AI_BOARD_COOLDOWN:-120}"
CONTEXT_COUNT="${AI_BOARD_CONTEXT_COUNT:-20}"
REPLY_MAX_LEN="${AI_BOARD_REPLY_MAX_LEN:-1500}"
STATE_FILE="${AI_BOARD_STATE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/ai-board/last-id}"
COOLDOWN_FILE="${STATE_FILE}.cooldown"
LOCK_DIR="${STATE_FILE}.lock"
MODE="loop"
[[ "${1:-}" == "--once" ]] && MODE="once"

# --- validasi angka ---
for var in POLL_INTERVAL BATCH_WINDOW COOLDOWN CONTEXT_COUNT REPLY_MAX_LEN; do
  [[ "${!var}" =~ ^[0-9]+$ ]] || { echo "board-agent: $var harus angka, dapat: ${!var}" >&2; exit 1; }
done

# --- dependensi ---
for cmd in curl jq opencode; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "board-agent: butuh '$cmd' tapi tidak ada di PATH" >&2; exit 1; }
done

# cd ke root repo biar opencode dapat konteks project (aman untuk cron)
cd "$(dirname "$0")/.."
# load .env kalau ada (AI_BOARD_* bisa ditaruh di sini)
if [[ -f .env ]]; then set -a; . ./.env; set +a; fi

mkdir -p "$(dirname "$STATE_FILE")"
mkdir "$LOCK_DIR" 2>/dev/null || exit 0   # cegah overlap (cron vs manual)
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT
WORKDIR="$(mktemp -d)"

log() { printf '[board-agent %s] %s\n' "$(date '+%F %T')" "$*"; }

board_get() { curl -fsS --max-time 20 "${BOARD_URL}$1"; }

last_seen() { cat "$STATE_FILE" 2>/dev/null || echo 0; }

count_new() {  # $1 = json dari board
  jq -r --arg bot "$BOT_SENDER" '[(.messages // [])[] | select(.sender != $bot)] | length' <<<"$1"
}

max_id() { jq -r '[(.messages // [])[].id] | max // 0' <<<"$1"; }

# Kumpulkan batch: setelah ketemu pesan baru, tunggu sebentar biar pesan yang
# masuk berdekatan diproses jadi satu sesi (hemat token, konteks utuh).
collect_batch() {
  local since="$1" json n rounds=0
  json="$(board_get "?since=$since&limit=50")"
  while (( rounds < 3 )); do
    n="$(count_new "$json")"
    (( n == 0 )) && break
    sleep "$BATCH_WINDOW"
    json="$(board_get "?since=$since&limit=50")"
    rounds=$((rounds + 1))
  done
  printf '%s' "$json"
}

# Inti kerja: susun prompt (konteks + pesan baru) -> opencode run -> post reply.
run_agent() {
  local json="$1"
  local msgs first_id ctx_json
  msgs="$(jq -c --arg bot "$BOT_SENDER" '[(.messages // [])[] | select(.sender != $bot)] | sort_by(.id)' <<<"$json")"
  first_id="$(jq -r '.[0].id' <<<"$msgs")"

  ctx_json="$(board_get "?limit=$CONTEXT_COUNT")" || { log "gagal fetch konteks board"; return 1; }

  {
    cat <<'HDR'
Kamu adalah agent yang bertugas memantau dan membalas AI Message Board (papan pesan AI-to-AI).
Di bawah ini konteks percakapan terakhir di board, lalu pesan-pesan baru yang harus kamu tangani.

=== KONTEKS BOARD (pesan lama, lama -> baru) ===
HDR
    jq -r --argjson n "$CONTEXT_COUNT" \
      '(.messages // []) | sort_by(.id) | reverse | .[:$n] | reverse | .[] |
       "#\(.id) [\(.sender)] \(.ts) | \(.subject // "(no subject)")\n\((.body // "") | if length > 300 then .[0:300] + " …(dipotong)" else . end)\n"' \
      <<<"$ctx_json"
    cat <<'MID'
=== PESAN BARU UNTUK KAMU TANGANI ===
MID
    jq -r '.[] |
       "#\(.id) dari \(.sender) [\(.ts)]\nsubject: \(.subject // "(kosong)")\n\((.body // "") | if length > 2000 then .[0:2000] + " …(dipotong)" else . end)\n---"' \
      <<<"$msgs"
    cat <<'FTR'
=== INSTRUKSI ===
1. Baca konteks dulu supaya kamu paham obrolannya; jangan tanya ulang hal yang sudah jelas di konteks.
2. Tangani permintaan/pertanyaan di pesan-pesan baru di atas. Kalau butuh info dari repo/project, cek langsung (kamu punya tools).
3. Jawab RINGKAS dan padat (maks ~15 baris) — jawabanmu OTOMATIS dipost ke board sebagai balasan, jadi tulis jawaban final saja.
4. JANGAN memanggil curl/API board untuk membalas — script yang akan mem-post jawabanmu. Jangan juga memproses pesan lama lain.
5. Kalau pesan barunya cuma info/laporan tanpa permintaan, balas singkat: poin penting + insight atau langkah lanjutan yang relevan.
FTR
  } > "$WORKDIR/prompt.txt"
  printf 'Board API: %s (info saja; kamu tidak perlu mem-post manual).\n' "$BOARD_URL" >> "$WORKDIR/prompt.txt"

  log "jalankan opencode untuk pesan baru sejak #$first_id (model: ${MODEL:-default config})"
  date +%s > "$COOLDOWN_FILE"   # cooldown dihitung dari mulai run (run bisa lama)

  local out="" rc=0
  if [[ -n "$MODEL" ]]; then
    out="$(opencode run --model "$MODEL" "$(cat "$WORKDIR/prompt.txt")" 2>"$WORKDIR/err.txt")" || rc=$?
  else
    out="$(opencode run "$(cat "$WORKDIR/prompt.txt")" 2>"$WORKDIR/err.txt")" || rc=$?
  fi

  if (( rc != 0 )); then
    log "ERROR: opencode run exit=$rc; stderr: $(tail -c 300 "$WORKDIR/err.txt" 2>/dev/null || echo '?')"
  fi

  local body
  body="$(printf '%s' "$out" | tr -d '\000' | head -c "$REPLY_MAX_LEN")"
  [[ -z "${body// }" ]] && body="(agent tidak menghasilkan output — cek log board-agent)"

  if curl -fsS --max-time 20 -X POST "$BOARD_URL" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg sender "$BOT_SENDER" --arg subject "Re: #$first_id" --arg body "$body" \
            '{sender:$sender,subject:$subject,body:$body}')" >/dev/null; then
    log "reply dipost: Re: #$first_id"
  else
    log "ERROR: gagal post reply ke board"
  fi
  date +%s > "$COOLDOWN_FILE"
}

tick() {
  # First run: mulai dari id terkini, jangan replay seluruh riwayat board.
  if [[ ! -s "$STATE_FILE" ]]; then
    local init_json
    init_json="$(board_get "?limit=1")" || { log "gagal fetch board (init state)"; return 1; }
    printf '%s' "$(max_id "$init_json")" > "$STATE_FILE"
    log "state awal: mulai dari id $(cat "$STATE_FILE")"
  fi

  local since lastrun now
  since="$(last_seen)"

  lastrun="$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if (( now - lastrun < COOLDOWN )); then
    log "cooldown aktif, sisa $(( COOLDOWN - (now - lastrun) ))s — skip tick"
    return 0
  fi

  local json n mid
  json="$(collect_batch "$since")" || { log "gagal fetch board"; return 1; }
  n="$(count_new "$json")"

  # Watermark selalu dimajukan (termasuk pesan bot sendiri) biar ga refetch terus.
  mid="$(max_id "$json")"
  if (( mid > since )); then printf '%s' "$mid" > "$STATE_FILE"; fi

  if (( n == 0 )); then
    log "tidak ada pesan baru (last=$mid)"
    return 0
  fi
  run_agent "$json"
}

main() {
  if [[ "$MODE" == "once" ]]; then
    tick || log "tick gagal (exit $?)"
  else
    log "daemon mulai — polling tiap ${POLL_INTERVAL}s dari $BOARD_URL (sender bot: $BOT_SENDER)"
    while true; do
      tick || log "tick gagal (exit $?)"
      sleep "$POLL_INTERVAL"
    done
  fi
}

main "$@"
