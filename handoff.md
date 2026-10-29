# Handoff — Sesi Otomatisasi AI Board

**Tanggal:** 2026-09-19
**Repo:** `ai-board` (live: https://ai-board-azure.vercel.app)
**Stack:** Turso Cloud (DB) · Vercel serverless (`api/proxy.js`) · `index.html` vanilla

## Tujuan Sesi

Board sebelumnya manual: user harus nyuruh agent OpenCode untuk cek board. Goal: agent **otomatis** membaca pesan baru dan membalas ke board tanpa disuruh.

## Yang Sudah Dikerjakan

### 1. `scripts/board-agent.sh` (BARU, chmod +x)

Polling agent: board → `opencode run` → reply ke board. Alur:

1. Poll `GET /api/messages?since=<last_id>`
2. Skip pesan dari sender bot (`opencode`) — **anti-loop**
3. Ada pesan baru → tunggu `BATCH_WINDOW` detik (batching pesan berdekatan)
4. Fetch 20 pesan terakhir sebagai konteks → susun prompt (**context injection**)
5. Jalankan `opencode run` (model bisa di-override via `AI_BOARD_MODEL`)
6. Post output agent sebagai `Re: #<first_id>` dengan sender `opencode`
7. Update watermark `last_id`

Fitur: batching, cooldown 120s, overlap lock (mkdir lock dir), first-run watermark = id terkini (tidak replay riwayat), fallback reply "(agent tidak menghasilkan output)" + log stderr kalau agent gagal.

Mode: `--once` (untuk cron) atau daemon (loop `POLL_INTERVAL`).

### 2. `README.md` (UPDATE)

Section baru "Otomatisasi: Agent Auto-Reply (OpenCode)": cara pakai, pilihan model (termasuk gratis), cron setup, tabel lengkap semua env var `AI_BOARD_*`.

### 3. E2E Test — PASSED ✅

| # | Sender | Isi |
|---|--------|-----|
| 41 | nixbox | Pesan tes `[TODO] E2E test otomatisasi` |
| 42 | opencode | Fallback reply — run pertama GAGAL (lihat temuan #1) |
| 43 | opencode | Reply valid dari model `opencode/nemotron-3.5-lightning-free` |

Pipeline lengkap terbukti: post pesan → agent pick-up otomatis → reply ke board.

## Temuan Penting

1. **Model default user MATI.** Config `~/.config/opencode/opencode.jsonc` pakai `experiential-anthropic/deepseek-v4-flash` → error `insufficient_credits` (balance $0.00). Wajib set model gratis via `AI_BOARD_MODEL`.
2. **`opencode` v1.18.21 terinstall di sandbox**, auth tersedia: OpenRouter, DeepSeek, tabitoken. Free models tersedia, mis. `opencode/nemotron-3.5-lightning-free` (terbukti jalan, ~2 menit/run).
3. **Sender user di board ternyata `soar-nixbox`** (bukan `nixbox` seperti di README lama). Tidak masalah saat ini (semua non-bot memicu), tapi relevan kalau nanti ditambah filter sender.
4. Run free model ~2 menit → cooldown default 120s sudah pas.

## Next Steps (urutan prioritas)

1. [ ] **Set model gratis** di `.env`: `AI_BOARD_MODEL=opencode/nemotron-3.5-lightning-free` (atau model pilihan user — cek `opencode models`)
2. [ ] **Pasang cron** di mesin user:
   ```
   * * * * * cd /path/ke/ai-board && ./scripts/board-agent.sh --once >> /tmp/board-agent.log 2>&1
   ```
3. [ ] Verifikasi jangka panjang di mesin user (cron jalan, state file ter-update, reply muncul di board)
4. [ ] Opsional: hapus pesan tes #41–43 langsung di Turso (API tidak punya endpoint delete)
5. [ ] Opsional: filter trigger per-sender (mis. env `AI_BOARD_TRIGGER_SENDERS`) — filter ditambah di fungsi `count_new`
6. [ ] Opsional: evaluasi opsi B (plugin OpenCode, hook `event.idle`) kalau mau memori antar pesan tanpa context injection

## Catatan Teknis

- State file default: `~/.cache/ai-board/last-id` (override: `AI_BOARD_STATE_FILE`). Lock dir: `<state-file>.lock`.
- Semua config via env `AI_BOARD_*` — daftar lengkap di README. Bisa ditaruh di `.env` root (script me-load-nya).
- Board API: `GET /api/messages?since=N&limit=M` · `POST /api/messages {sender, subject, body}`.
- Prompt agent dilarang mem-post sendiri ke board (script yang mem-post) — cegah double-post.
- Jangan commit `.env` (sudah di .gitignore).

## File Berubah Sesi Ini

- `scripts/board-agent.sh` — BARU
- `README.md` — section otomatisasi baru
- `handoff.md` — file ini
