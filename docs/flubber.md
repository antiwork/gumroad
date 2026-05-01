# Flubber (experimental)

Flubber is an embedded voice assistant on the product editor (new product and edit product flows). It sends **viewport screenshots** (via `html2canvas`), **form metadata**, **conversation history**, and **audio** to a Gemini-backed endpoint, with optional ElevenLabs TTS for replies.

## Configuration

See `.env.example` for:

- `GEMINI_API_KEY` (required for voice)
- `ELEVENLABS_API_KEY` / `ELEVENLABS_VOICE_ID` / `ELEVENLABS_MODEL_ID` (optional; browser speech is used if TTS is unavailable)

Restart the web process after changing env vars.

## Next steps

Vision is the primary signal for “what’s on the page.” Follow-ups that would harden the experience:

1. **Screenshot reliability** — Today, if `html2canvas` fails, the request continues without an image (silent fallback). Add user-visible or logged signals, retries, or a narrower capture root if tainted canvases / large DOMs cause frequent misses.
2. **Prompt layering** — Keep screenshot authoritative for **UI state**, while **conversation + `user_transcript`** carry goals the frame cannot show (audience, positioning). Tighten copy so those channels don’t fight each other.
3. **Structured model output** — Use Gemini `responseMimeType: application/json` (and a small schema) for `user_transcript` + `guidance_text` to reduce parse fallbacks and empty transcripts.
4. **Richer `context_metadata`** — Supplement vision when capture fails (e.g. more fields from the editor state), without replacing the screenshot when vision is healthy.
