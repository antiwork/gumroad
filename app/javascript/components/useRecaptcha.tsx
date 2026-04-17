import * as React from "react";

const RECAPTCHA_SCRIPT_URL = "https://www.google.com/recaptcha/enterprise.js?render=explicit";
const RECAPTCHA_TIMEOUT_MS = 10_000;

let loadPromise: Promise<void> | null = null;

const loadRecaptchaScript = (): Promise<void> => {
  if ("grecaptcha" in window) {
    return Promise.resolve();
  }

  if (loadPromise) {
    return loadPromise;
  }

  loadPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = RECAPTCHA_SCRIPT_URL;
    script.async = true;
    script.onload = () => {
      resolve();
    };
    script.onerror = () => {
      loadPromise = null;
      reject(new Error("Failed to load reCAPTCHA script"));
    };
    document.head.appendChild(script);
  });

  return loadPromise;
};

export function useRecaptcha({ siteKey }: { siteKey: string | null }) {
  const containerRef = React.useRef<HTMLDivElement | null>(null);
  const recaptchaId = React.useRef<number | null>(null);
  const resolveRef = React.useRef<((response: string) => void) | null>(null);

  React.useEffect(() => {
    if (!siteKey) return;

    const initRecaptcha = () => {
      grecaptcha.enterprise.ready(() => {
        if (!containerRef.current || containerRef.current.childElementCount) return;
        recaptchaId.current = grecaptcha.enterprise.render(containerRef.current, {
          sitekey: siteKey,
          callback: (response) => {
            resolveRef.current?.(response);
            resolveRef.current = null;
          },
          size: "invisible",
        });
      });
    };

    loadRecaptchaScript()
      .then(initRecaptcha)
      .catch(() => {});
  }, [siteKey]);

  const execute = () => {
    const widgetId = recaptchaId.current;
    if (widgetId === null) return Promise.reject(new Error("reCAPTCHA not initialized"));
    grecaptcha.enterprise.reset(widgetId);
    void grecaptcha.enterprise.execute(widgetId);
    return new Promise<string>((resolve, reject) => {
      resolveRef.current = resolve;
      setTimeout(() => {
        if (resolveRef.current) {
          resolveRef.current = null;
          reject(new Error("reCAPTCHA timed out"));
        }
      }, RECAPTCHA_TIMEOUT_MS);
    });
  };

  return { container: <div ref={containerRef} style={{ display: "contents" }} />, execute };
}
