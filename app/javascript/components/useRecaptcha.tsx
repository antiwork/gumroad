import * as React from "react";

export class RecaptchaCancelledError extends Error {}

const SCRIPT_BASE_URL = "https://www.google.com/recaptcha/enterprise.js";
const CHALLENGE_SCRIPT_URL = `${SCRIPT_BASE_URL}?render=explicit`;
const scoreScriptUrl = (siteKey: string) => `${SCRIPT_BASE_URL}?render=${encodeURIComponent(siteKey)}`;

const loadPromises = new Map<string, Promise<void>>();

const loadRecaptchaScript = (url: string): Promise<void> => {
  const existing = loadPromises.get(url);
  if (existing) return existing;

  const promise = new Promise<void>((resolve, reject) => {
    const script = document.createElement("script");
    script.src = url;
    script.async = true;
    script.onload = () => {
      resolve();
    };
    script.onerror = () => {
      loadPromises.delete(url);
      reject(new Error("Failed to load reCAPTCHA script"));
    };
    document.head.appendChild(script);
  });

  loadPromises.set(url, promise);
  return promise;
};

const isRecaptchaIframe = (node: Node) =>
  node instanceof HTMLIFrameElement && node.src.includes("google.com/recaptcha");

const listenForRecaptchaCancel = (widgetId: number, onCancel: () => void) => {
  let recaptchaContainerObserver: MutationObserver | null = null;

  // Recaptcha doesn't have an API to detect when the user clicks away from the captcha
  // without selecting anything. To work around this, we first detect the recaptcha
  // prompt container being added, then we listen for it becoming invisible (which happens
  // when the user dismisses the prompt). Note that recaptcha currently recreates the
  // container on reset, so we need to handle recaptchaContainer changing.
  const observer = new MutationObserver((changes) => {
    if (changes.some((change) => [...change.removedNodes].some(isRecaptchaIframe))) {
      recaptchaContainerObserver?.disconnect();
      observer.disconnect();
      return;
    }

    const recaptchaIframe = changes.flatMap((change) => [...change.addedNodes]).find(isRecaptchaIframe);
    const recaptchaContainer = recaptchaIframe?.parentElement?.parentElement;
    if (!recaptchaContainer) return;

    recaptchaContainerObserver = new MutationObserver(() => {
      if (recaptchaContainer.style.visibility === "hidden" && !grecaptcha.enterprise.getResponse(widgetId)) onCancel();
    });
    recaptchaContainerObserver.observe(recaptchaContainer, { attributes: true });
  });
  observer.observe(document.body, { childList: true, subtree: true });
};

// `scoreBased` switches between the two reCAPTCHA Enterprise key types:
//   - challenge keys (default): an invisible widget that Google may escalate to
//     an interactive image challenge. Rendered via render() + execute(widgetId).
//   - score keys: never render a challenge — they return a 0.0–1.0 risk score
//     that the server gates on. Invoked programmatically via execute(siteKey,
//     { action }); no widget, container, or cancel handling is involved.
export function useRecaptcha({
  siteKey,
  scoreBased = false,
  action = "checkout",
}: {
  siteKey: string | null;
  scoreBased?: boolean;
  action?: string;
}) {
  const containerRef = React.useRef<HTMLDivElement | null>(null);
  const recaptchaId = React.useRef<number | null>(null);
  const resolveRef = React.useRef<((response: string) => void) | null>(null);

  React.useEffect(() => {
    if (!siteKey) return;

    if (scoreBased) {
      // No widget to render. Preload the script so the first execute() doesn't
      // pay the load latency. The render=<siteKey> form is required for
      // grecaptcha.enterprise.execute(siteKey, ...) to resolve a token.
      loadRecaptchaScript(scoreScriptUrl(siteKey)).catch(() => {});
      return;
    }

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

    loadRecaptchaScript(CHALLENGE_SCRIPT_URL)
      .then(initRecaptcha)
      .catch(() => {});
  }, [siteKey, scoreBased]);

  const execute = () => {
    if (!siteKey) return Promise.reject(new RecaptchaCancelledError());

    if (scoreBased) {
      return (
        loadRecaptchaScript(scoreScriptUrl(siteKey))
          .then(
            () =>
              new Promise<string>((resolve, reject) => {
                grecaptcha.enterprise.ready(() => {
                  grecaptcha.enterprise.execute(siteKey, { action }).then(resolve, () => {
                    reject(new RecaptchaCancelledError());
                  });
                });
              }),
          )
          // Normalize any pre-token failure (e.g. the script being blocked or
          // failing to load) to RecaptchaCancelledError so callers can treat it
          // like a dismissed challenge and reset, rather than hanging.
          .catch(() => Promise.reject(new RecaptchaCancelledError()))
      );
    }

    const widgetId = recaptchaId.current;
    if (widgetId === null) return Promise.reject(new RecaptchaCancelledError());
    grecaptcha.enterprise.reset(widgetId);
    void grecaptcha.enterprise.execute(widgetId);
    // This promise should always complete if recaptcha works correctly, but it's not guaranteed to (e.g.
    // if recaptcha's DOM structure ever changes, or if there's an error during their processing).
    return new Promise<string>((resolve, reject) => {
      listenForRecaptchaCancel(widgetId, () => {
        reject(new RecaptchaCancelledError());
        resolveRef.current = null;
      });
      resolveRef.current = resolve;
    });
  };

  return {
    container: scoreBased ? null : <div ref={containerRef} style={{ display: "contents" }} />,
    execute,
  };
}
