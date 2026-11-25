import * as React from "react";

import { cast } from "$app/utils/cast";

// The Web Speech API, as far as the search bar uses it. Chrome and Safari ship it prefixed, and
// TypeScript's DOM types leave the recogniser itself out.
type Recognition = {
  lang: string;
  interimResults: boolean;
  start: () => void;
  abort: () => void;
  onresult: ((event: { results: ArrayLike<ArrayLike<{ transcript: string }>> }) => void) | null;
  onend: (() => void) | null;
  onerror: ((event: { error: string }) => void) | null;
};

const recognitionConstructor = () => {
  if (typeof window === "undefined") return null;
  const found: unknown = Reflect.get(window, "SpeechRecognition") ?? Reflect.get(window, "webkitSpeechRecognition");
  return typeof found === "function" ? cast<new () => Recognition>(found) : null;
};

export const isDictationSupported = () => recognitionConstructor() !== null;

/** Speech to text for one field: `onText` gets what has been heard so far, replacing the last call's text. */
export const useDictation = (onText: (text: string) => void) => {
  const [listening, setListening] = React.useState(false);
  // "blocked" is a refused microphone; anything else is worth another try.
  const [error, setError] = React.useState<"blocked" | "failed" | null>(null);
  const recognition = React.useRef<Recognition | null>(null);
  const handler = React.useRef(onText);
  handler.current = onText;

  const stop = React.useCallback(() => {
    recognition.current?.abort();
    recognition.current = null;
    setListening(false);
  }, []);

  const start = React.useCallback(() => {
    const Constructor = recognitionConstructor();
    if (!Constructor || recognition.current) return;
    const instance = new Constructor();
    instance.lang = document.documentElement.lang || navigator.language;
    instance.interimResults = true;
    instance.onresult = (event) =>
      handler.current(
        Array.from(event.results, (result) => result[0]?.transcript ?? "")
          .join(" ")
          .trim(),
      );
    instance.onerror = (event) => {
      // Silence and a deliberate stop are not failures.
      if (event.error === "no-speech" || event.error === "aborted") return;
      setError(event.error === "not-allowed" || event.error === "service-not-allowed" ? "blocked" : "failed");
    };
    instance.onend = () => {
      if (recognition.current === instance) recognition.current = null;
      setListening(false);
    };
    recognition.current = instance;
    setError(null);
    setListening(true);
    try {
      instance.start();
    } catch {
      recognition.current = null;
      setListening(false);
      setError("failed");
    }
  }, []);

  React.useEffect(() => stop, [stop]);

  return { listening, error, start, stop };
};
