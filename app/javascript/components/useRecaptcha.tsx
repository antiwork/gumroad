import * as React from "react";

export class RecaptchaCancelledError extends Error {}

// Thrown when reCAPTCHA itself never produced a token for a reason that was NOT the user
// dismissing a challenge — most commonly the Google script being blocked by an ad blocker /
// privacy extension, or failing to load on a restricted network. Callers should surface
// actionable guidance for this case instead of failing silently: the buyer can fix it
// themselves (disable the extension for this page, use a private window, or switch networks),
// but only if we tell them.
export class RecaptchaUnavailableError extends Error {}

// The buyer-facing guidance for RecaptchaUnavailableError. Shared so every checkout surface
// shows the same message. Kept in sync with the server-side CAPTCHA failure message in
// OrdersController / PurchasesController.
export const RECAPTCHA_UNAVAILABLE_MESSAGE =
  "We couldn't load the security check. This is often caused by an ad blocker or privacy extension — try disabling it for this page, using a private/incognito window, or switching networks, then try again.";

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
  // Tracks the script-load + widget-render sequence so execute() can wait for it. Without
  // this, a submit that happens before initialization finishes would see a missing widget
  // and wrongly report the CAPTCHA as unavailable (blocked), when it was simply still loading.
  const initPromiseRef = React.useRef<Promise<void> | null>(null);

  React.useEffect(() => {
    if (!siteKey) return;

    if (scoreBased) {
      // No widget to render. Preload the script so the first execute() doesn't
      // pay the load latency. The render=<siteKey> form is required for
      // grecaptcha.enterprise.execute(siteKey, ...) to resolve a token.
      loadRecaptchaScript(scoreScriptUrl(siteKey)).catch(() => {});
      return;
    }

    const initRecaptcha = () =>
      new Promise<void>((resolve) => {
        grecaptcha.enterprise.ready(() => {
          if (containerRef.current && !containerRef.current.childElementCount) {
            recaptchaId.current = grecaptcha.enterprise.render(containerRef.current, {
              sitekey: siteKey,
              callback: (response) => {
                resolveRef.current?.(response);
                resolveRef.current = null;
              },
              size: "invisible",
            });
          }
          resolve();
        });
      });

    const initPromise = loadRecaptchaScript(CHALLENGE_SCRIPT_URL).then(initRecaptcha);
    initPromiseRef.current = initPromise;
    // Swallow the rejection here so a blocked script doesn't surface as an unhandled promise
    // rejection — execute() re-checks the stored promise and reports the failure to the user.
    initPromise.catch(() => {});
  }, [siteKey, scoreBased]);

  const execute = () => {
    if (!siteKey) return Promise.reject(new RecaptchaCancelledError());

    if (scoreBased) {
      return loadRecaptchaScript(scoreScriptUrl(siteKey))
        .catch(() => {
          // The script failing to load is environmental (blocked by an extension or the
          // network), not a user dismissal — surface it as such so the UI can show guidance.
          throw new RecaptchaUnavailableError();
        })
        .then(
          () =>
            new Promise<string>((resolve, reject) => {
              grecaptcha.enterprise.ready(() => {
                grecaptcha.enterprise.execute(siteKey, { action }).then(resolve, () => {
                  // Score keys never show a challenge, so there is nothing for the user to
                  // dismiss — a token failure here is also environmental.
                  reject(new RecaptchaUnavailableError());
                });
              });
            }),
        );
    }

    // Wait for initialization to finish before checking the widget: a submit that lands
    // before the script has loaded and rendered the widget is a normal timing race, not a
    // blocked CAPTCHA, so we must not report it as unavailable prematurely.
    const initPromise = initPromiseRef.current ?? Promise.reject(new Error("reCAPTCHA was never initialized"));
    return initPromise
      .catch(() => {
        // The script failing to load is environmental (blocked by an extension or the
        // network), not a user dismissal — surface it as such so the UI can show guidance.
        throw new RecaptchaUnavailableError();
      })
      .then(() => {
        const widgetId = recaptchaId.current;
        // Initialization finished but no widget exists — the reCAPTCHA script loaded without
        // producing a usable challenge (or its container never mounted), so the challenge can
        // never run. Distinct from the user dismissing a rendered challenge.
        if (widgetId === null) throw new RecaptchaUnavailableError();
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
      });
  };

  return {
    container: scoreBased ? null : <div ref={containerRef} style={{ display: "contents" }} />,
    execute,
  };
}
