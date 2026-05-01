import html2canvas from "html2canvas";
import * as React from "react";
import * as ReactDOM from "react-dom";

import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { useRunOnce } from "$app/components/useRunOnce";

import flubberCursorImg from "./flubber-cursor.png";
import "./flubber.css";

const AVAILABLE_ELEMENTS = ["product-type", "product-name", "cover-upload", "pricing", "publish-button"] as const;

/** Prior turns only (completed user + assistant pairs); capped client-side to match the API. */
const MAX_CONVERSATION_MESSAGES = 40;
const CAPTURE_MAX_WIDTH = 1200;
const CAPTURE_MAX_HEIGHT = 1400;
const CAPTURE_QUALITY = 0.6;
const MOUSE_DISTANCE = 24;
const MOUSE_OFFSET = Math.round(MOUSE_DISTANCE / Math.sqrt(2));

const POINT_PATTERN = /\[POINT:([^\]]+)\]/g;
const FLUBBER_ONBOARDING_DISMISSED_KEY = "gumroad_flubber_product_onboarding_dismissed";

export type FlubberChatTurn = { role: "user" | "assistant"; content: string };

function lerp(a: number, b: number, t: number) {
  return a + (b - a) * t;
}

type FlubberContextMetadata = {
  current_route: string;
  current_tab: "product" | "content" | "receipt" | "share" | "unknown";
  field_state: {
    product_type?: string;
    product_name_filled: boolean;
    pricing_filled: boolean;
  };
};

function stripPointTags(text: string) {
  return text.replace(POINT_PATTERN, "").replace(/\s+/g, " ").trim();
}

async function captureFlubberContextImage() {
  const root = document.documentElement;

  const canvas = await html2canvas(root, {
    useCORS: true,
    backgroundColor: "#ffffff",
    scale: 1,
    logging: false,
    width: window.innerWidth,
    height: window.innerHeight,
    windowWidth: window.innerWidth,
    windowHeight: window.innerHeight,
    x: window.scrollX,
    y: window.scrollY,
    scrollX: window.scrollX,
    scrollY: window.scrollY,
  });

  const scale = Math.min(1, CAPTURE_MAX_WIDTH / canvas.width, CAPTURE_MAX_HEIGHT / canvas.height);
  const targetWidth = Math.max(1, Math.floor(canvas.width * scale));
  const targetHeight = Math.max(1, Math.floor(canvas.height * scale));

  if (scale < 1) {
    const resized = document.createElement("canvas");
    resized.width = targetWidth;
    resized.height = targetHeight;
    const ctx = resized.getContext("2d");
    if (!ctx) return canvas.toDataURL("image/jpeg", CAPTURE_QUALITY);
    ctx.drawImage(canvas, 0, 0, targetWidth, targetHeight);
    return resized.toDataURL("image/jpeg", CAPTURE_QUALITY);
  }

  return canvas.toDataURL("image/jpeg", CAPTURE_QUALITY);
}

function detectCurrentTab(pathname: string): FlubberContextMetadata["current_tab"] {
  if (pathname.endsWith("/content")) return "content";
  if (pathname.endsWith("/receipt")) return "receipt";
  if (pathname.endsWith("/share")) return "share";
  if (pathname.includes("/products/new") || pathname.includes("/edit")) return "product";
  return "unknown";
}

function buildFlubberContextMetadata(): FlubberContextMetadata {
  const pathname = window.location.pathname;
  const productTypeButton = document.querySelector<HTMLElement>('[data-type][aria-checked="true"]');
  const productNameInput = document.querySelector<HTMLInputElement>("#name, input[id*='name-'], input[name*='name']");
  const priceInput = document.querySelector<HTMLInputElement>("#price, input[id*='price-'], input[name*='price']");
  const productType = productTypeButton?.dataset.type;

  const fieldState: FlubberContextMetadata["field_state"] = {
    product_name_filled: !!productNameInput?.value?.trim(),
    pricing_filled: !!priceInput?.value?.trim(),
  };
  if (productType) fieldState.product_type = productType;

  return {
    current_route: pathname,
    current_tab: detectCurrentTab(pathname),
    field_state: fieldState,
  };
}

function highlightElements(rawReply: string) {
  let match: RegExpExecArray | null;
  const re = /\[POINT:([^\]]+)\]/g;
  const seen = new Set<string>();
  while ((match = re.exec(rawReply)) !== null) {
    const name = match[1]?.trim();
    if (!name || seen.has(name)) continue;
    seen.add(name);

    const el = document.querySelector(`[data-flubber="${CSS.escape(name)}"]`);
    if (!(el instanceof HTMLElement)) continue;

    el.scrollIntoView({ behavior: "smooth", block: "nearest" });
    el.setAttribute("data-flubber-active", "");
    window.setTimeout(() => {
      el.removeAttribute("data-flubber-active");
    }, 2000);
  }
}

type VoiceStatus = "idle" | "listening" | "thinking" | "speaking" | "error";

export const FlubberPanel = () => {
  const [showOnboarding, setShowOnboarding] = React.useState(false);
  const [open, setOpen] = React.useState(false);
  const [historyOpen, setHistoryOpen] = React.useState(false);
  const [status, setStatus] = React.useState<VoiceStatus>("idle");
  const [isPressingToTalk, setIsPressingToTalk] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);
  const [voiceHint, setVoiceHint] = React.useState<string | null>(null);
  const [lastGuidanceAt, setLastGuidanceAt] = React.useState<number | null>(null);
  const [history, setHistory] = React.useState<FlubberChatTurn[]>([]);

  const blobPos = React.useRef({
    x: typeof window !== "undefined" ? window.innerWidth / 2 : 0,
    y: typeof window !== "undefined" ? window.innerHeight / 2 : 0,
  });
  const mouse = React.useRef({
    x: typeof window !== "undefined" ? window.innerWidth / 2 : 0,
    y: typeof window !== "undefined" ? window.innerHeight / 2 : 0,
  });
  const blobRef = React.useRef<HTMLButtonElement>(null);
  const panelRef = React.useRef<HTMLDivElement>(null);
  const frameRef = React.useRef<number>();
  const mediaRecorderRef = React.useRef<MediaRecorder | null>(null);
  const mediaChunksRef = React.useRef<BlobPart[]>([]);
  const streamRef = React.useRef<MediaStream | null>(null);
  const audioRef = React.useRef<HTMLAudioElement | null>(null);
  const sessionIdRef = React.useRef<string>(crypto.randomUUID());
  const conversationRef = React.useRef<FlubberChatTurn[]>([]);

  const dismissOnboarding = () => {
    try {
      localStorage.setItem(FLUBBER_ONBOARDING_DISMISSED_KEY, "true");
    } catch {
      /* private mode or quota */
    }
    setShowOnboarding(false);
  };

  useRunOnce(() => {
    try {
      if (localStorage.getItem(FLUBBER_ONBOARDING_DISMISSED_KEY) !== "true") {
        setShowOnboarding(true);
      }
    } catch {
      /* storage unavailable — skip nag */
    }
  });

  React.useEffect(() => {
    const onMove = (e: MouseEvent) => {
      mouse.current = { x: e.clientX, y: e.clientY };
    };
    window.addEventListener("mousemove", onMove);
    return () => window.removeEventListener("mousemove", onMove);
  }, []);

  React.useEffect(() => {
    const tick = () => {
      const tx = mouse.current.x + MOUSE_OFFSET;
      const ty = mouse.current.y + MOUSE_OFFSET;
      blobPos.current = {
        x: lerp(blobPos.current.x, tx, 0.12),
        y: lerp(blobPos.current.y, ty, 0.12),
      };
      const el = blobRef.current;
      if (el) {
        const size = 24;
        el.style.transform = `translate(${blobPos.current.x - size / 2}px, ${blobPos.current.y - size / 2}px)`;
      }
      frameRef.current = window.requestAnimationFrame(tick);
    };
    frameRef.current = window.requestAnimationFrame(tick);
    return () => {
      if (frameRef.current) cancelAnimationFrame(frameRef.current);
    };
  }, []);

  React.useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape" && showOnboarding) return;

      if (e.key === "Escape" && open) {
        e.preventDefault();
        if (historyOpen) {
          setHistoryOpen(false);
        } else {
          setOpen(false);
        }
        return;
      }

      const cmdOrCtrlSlash = (e.metaKey || e.ctrlKey) && e.key === "/";
      if (cmdOrCtrlSlash) {
        e.preventDefault();
        setOpen((wasOpen) => !wasOpen);
        return;
      }

      if (open) return;
      if (e.key !== "/" || e.metaKey || e.ctrlKey) return;
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
      e.preventDefault();
      setOpen(true);
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [open, historyOpen, showOnboarding]);

  React.useEffect(() => {
    if (!open) return;

    const onPointerDown = (e: PointerEvent) => {
      const panel = panelRef.current;
      const blob = blobRef.current;
      if (panel?.contains(e.target as Node)) return;
      if (blob?.contains(e.target as Node)) return;
      setOpen(false);
    };

    document.addEventListener("pointerdown", onPointerDown);
    return () => document.removeEventListener("pointerdown", onPointerDown);
  }, [open]);

  React.useEffect(() => {
    return () => {
      audioRef.current?.pause();
      if (streamRef.current) streamRef.current.getTracks().forEach((t) => t.stop());
    };
  }, []);

  const stopPlayback = () => {
    if (audioRef.current) {
      audioRef.current.pause();
      audioRef.current.currentTime = 0;
      audioRef.current = null;
    }
    window.speechSynthesis.cancel();
    if (status === "speaking") setStatus("idle");
  };

  const sendVoiceTurn = async (audioBlob: Blob) => {
    setStatus("thinking");
    setError(null);
    setVoiceHint(null);

    try {
      let contextImageDataUrl: string | null = null;
      try {
        contextImageDataUrl = await captureFlubberContextImage();
      } catch {
        // Silent fallback to text-only requests if capture fails.
      }

      const formData = new FormData();
      formData.append("voice_session_id", sessionIdRef.current);
      formData.append("audio_chunk", audioBlob, "flubber-voice.webm");
      formData.append("conversation", JSON.stringify(conversationRef.current.slice(-MAX_CONVERSATION_MESSAGES)));
      formData.append("available_elements", JSON.stringify([...AVAILABLE_ELEMENTS]));
      formData.append("context_metadata", JSON.stringify(buildFlubberContextMetadata()));
      if (contextImageDataUrl) formData.append("context_image_data_url", contextImageDataUrl);

      const response = await request({
        method: "POST",
        url: "/api/flubber/voice_turn",
        accept: "json",
        data: formData,
      });

      const body = (await response.json()) as {
        success: boolean;
        audio_base64?: string;
        audio_mime_type?: string;
        guidance_text?: string;
        user_transcript?: string;
        error?: string;
        tts_skip_reason?: string;
        tts_error_detail?: string;
        tts_hint_code?: string;
      };

      if (!body.success) {
        setError(body.error ?? "Something went wrong.");
        setStatus("error");
        return;
      }

      const rawGuidance = body.guidance_text ?? "";
      if (rawGuidance) {
        highlightElements(rawGuidance);
        const userContent = body.user_transcript?.trim() || "[voice input]";
        const userTurn: FlubberChatTurn = { role: "user", content: userContent };
        const assistantTurn: FlubberChatTurn = { role: "assistant", content: stripPointTags(rawGuidance) };
        const nextConversation: FlubberChatTurn[] = [...conversationRef.current, userTurn, assistantTurn].slice(
          -MAX_CONVERSATION_MESSAGES,
        );
        conversationRef.current = nextConversation;
        setHistory(nextConversation);
      }
      setLastGuidanceAt(Date.now());

      if (body.audio_base64 && body.audio_mime_type) {
        setVoiceHint(null);
        stopPlayback();
        setStatus("speaking");
        const speakable = stripPointTags(rawGuidance);
        const audio = new Audio(`data:${body.audio_mime_type};base64,${body.audio_base64}`);
        audioRef.current = audio;
        audio.onended = () => {
          setStatus("idle");
          audioRef.current = null;
        };
        try {
          await audio.play();
        } catch {
          // Autoplay is often blocked after async work without a fresh gesture; fall back to browser TTS.
          const utterance = new SpeechSynthesisUtterance(speakable);
          utterance.onend = () => setStatus("idle");
          utterance.onerror = () => setStatus("error");
          window.speechSynthesis.speak(utterance);
        }
      } else if (rawGuidance) {
        if (body.tts_skip_reason === "no_elevenlabs_api_key") {
          setVoiceHint(
            "ElevenLabs is not configured (set ELEVENLABS_API_KEY in .env and restart the web server). Using browser voice.",
          );
        } else if (body.tts_skip_reason === "elevenlabs_error") {
          if (body.tts_hint_code === "elevenlabs_library_voice_not_on_plan") {
            setVoiceHint(
              "ElevenLabs: the default voice is not available on your API plan. Set ELEVENLABS_VOICE_ID to a voice from your ElevenLabs account (My voices), or upgrade. Using browser voice.",
            );
          } else {
            setVoiceHint(
              `ElevenLabs failed${body.tts_error_detail ? `: ${body.tts_error_detail}` : ""}. Using browser voice.`,
            );
          }
        } else if (body.tts_skip_reason) {
          setVoiceHint(`Voice: ${body.tts_skip_reason}. Using browser voice.`);
        }
        setStatus("speaking");
        const utterance = new SpeechSynthesisUtterance(stripPointTags(rawGuidance));
        utterance.onend = () => setStatus("idle");
        utterance.onerror = () => setStatus("error");
        window.speechSynthesis.speak(utterance);
      } else {
        setStatus("idle");
      }
    } catch (e) {
      assertResponseError(e);
      setError("Something went wrong.");
      setStatus("error");
    }
  };

  const startListening = async () => {
    if (status === "thinking") return;
    stopPlayback();
    setError(null);

    if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) {
      setStatus("error");
      setError("Voice capture is not supported in this browser.");
      return;
    }

    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    streamRef.current = stream;
    mediaChunksRef.current = [];
    const recorder = new MediaRecorder(stream, { mimeType: "audio/webm" });
    mediaRecorderRef.current = recorder;

    recorder.ondataavailable = (event) => {
      if (event.data.size > 0) mediaChunksRef.current.push(event.data);
    };
    recorder.onstop = () => {
      const blob = new Blob(mediaChunksRef.current, { type: recorder.mimeType || "audio/webm" });
      stream.getTracks().forEach((t) => t.stop());
      streamRef.current = null;
      mediaRecorderRef.current = null;
      if (blob.size > 0) void sendVoiceTurn(blob);
      else setStatus("idle");
    };

    recorder.start();
    setStatus("listening");
  };

  const stopListening = () => {
    if (mediaRecorderRef.current && mediaRecorderRef.current.state !== "inactive") {
      mediaRecorderRef.current.stop();
    }
  };

  const holdToTalkStart = () => {
    setIsPressingToTalk(true);
    try {
      const AnyCtx =
        window.AudioContext || (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
      if (AnyCtx) {
        const ctx = new AnyCtx();
        void ctx.resume().finally(() => {
          void ctx.close();
        });
      }
    } catch {
      /* ignore */
    }
    if (status === "speaking") stopPlayback();
    void startListening();
  };

  const holdToTalkEnd = () => {
    setIsPressingToTalk(false);
    if (status === "listening") stopListening();
  };

  React.useEffect(() => {
    if (!open) return;

    const isTypingTarget = (target: EventTarget | null) => {
      const el = target as HTMLElement | null;
      return !!el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable);
    };

    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key.toLowerCase() !== "v") return;
      if (e.repeat || isTypingTarget(e.target)) return;
      e.preventDefault();
      holdToTalkStart();
    };

    const onKeyUp = (e: KeyboardEvent) => {
      if (e.key.toLowerCase() !== "v") return;
      e.preventDefault();
      holdToTalkEnd();
    };

    window.addEventListener("keydown", onKeyDown);
    window.addEventListener("keyup", onKeyUp);
    return () => {
      window.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("keyup", onKeyUp);
    };
  }, [open, status]);

  const flubberUi = (
    <>
      <Modal
        open={showOnboarding}
        onClose={dismissOnboarding}
        title="Meet Flubber"
        overlayClassName="z-[10000]"
        className="z-[10001]"
        footer={
          <Button type="button" color="primary" onClick={dismissOnboarding}>
            Got it
          </Button>
        }
      >
        <div className="flex items-start gap-3">
          <img
            src={flubberCursorImg}
            alt=""
            width={40}
            height={40}
            className="mt-0.5 size-10 shrink-0 object-contain select-none"
            draggable={false}
          />
          <p className="text-sm">
            Flubber helps you ship your product. Press <span className="font-medium">⌘/</span> or{" "}
            <span className="font-medium">Ctrl+/</span> to open it, then hold the button to talk.
          </p>
        </div>
      </Modal>
      <button
        type="button"
        ref={blobRef}
        className="fixed top-0 left-0 z-[9999] flex size-6 cursor-pointer items-center justify-center rounded-full border-0 bg-transparent p-0 drop-shadow-md"
        style={{ transform: "translate(0px, 0px)" }}
        aria-label="Flubber assistant (use Command-slash or Control-slash to open)"
        onClick={() => {
          setOpen((v) => !v);
        }}
      >
        <img
          src={flubberCursorImg}
          alt=""
          width={48}
          height={48}
          className="flubber-blob-img block size-6 max-h-6 max-w-6 object-contain select-none"
          draggable={false}
        />
      </button>

      {open ? (
        <div
          ref={panelRef}
          className="fixed right-4 bottom-4 z-[9998] flex w-72 max-w-[calc(100vw-2rem)] flex-col rounded border border-border bg-background p-3 shadow-lg"
          role="dialog"
          aria-label="Flubber voice assistant"
        >
          <div className="mb-2 flex items-start justify-between gap-2 border-b border-border pb-2">
            <div className="min-w-0 flex-1">
              <span className="text-sm font-semibold">Flubber</span>
              <div className="text-xs text-muted">⌘/ · Ctrl+/</div>
            </div>
            <button
              type="button"
              className="shrink-0 text-xs text-muted underline decoration-muted underline-offset-2 hover:text-foreground"
              onClick={() => setHistoryOpen((h) => !h)}
            >
              {historyOpen ? "Hide history" : "History"}
            </button>
          </div>
          {historyOpen ? (
            <div className="mb-3 max-h-40 min-h-0 overflow-y-auto rounded border border-border bg-background p-2 text-xs">
              {history.length === 0 ? (
                <span className="text-muted">No messages yet.</span>
              ) : (
                history.map((turn, i) => (
                  <div key={`${i}-${turn.role}`} className="mb-2 last:mb-0">
                    <span className="font-medium text-muted">{turn.role === "user" ? "You" : "Flubber"}</span>
                    {": "}
                    <span className="whitespace-pre-wrap text-foreground">{turn.content}</span>
                  </div>
                ))
              )}
            </div>
          ) : null}
          <div className="mb-3 rounded border border-border bg-primary/5 p-2 text-sm">
            {status !== "idle" ? (
              <div className="font-medium">
                {status === "listening" && "Listening... release to send"}
                {status === "thinking" && "Thinking..."}
                {status === "speaking" && "Speaking... press to interrupt"}
                {status === "error" && "Error"}
              </div>
            ) : null}
            {error ? <span className="text-danger">{error}</span> : null}
            {voiceHint ? <div className="mt-1 text-xs text-muted">{voiceHint}</div> : null}
            {lastGuidanceAt ? (
              <div className="text-xs text-muted">Last guidance: {new Date(lastGuidanceAt).toLocaleTimeString()}</div>
            ) : null}
          </div>
          <Button
            type="button"
            color={isPressingToTalk || status === "listening" ? "accent" : "primary"}
            className="w-full"
            onPointerDown={holdToTalkStart}
            onPointerUp={holdToTalkEnd}
            onPointerLeave={holdToTalkEnd}
            onTouchStart={holdToTalkStart}
            onTouchEnd={holdToTalkEnd}
            disabled={status === "thinking"}
          >
            {status === "listening" ? "Release to send (V)" : "Hold to talk (V)"}
          </Button>
        </div>
      ) : null}
    </>
  );

  if (typeof document !== "undefined" && document.body) {
    return ReactDOM.createPortal(flubberUi, document.body);
  }

  return flubberUi;
};
