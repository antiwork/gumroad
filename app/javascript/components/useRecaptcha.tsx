import * as React from "react";

export class RecaptchaCancelledError extends Error {}

const RECAPTCHA_SCRIPT_URL = "https://www.google.com/recaptcha/enterprise.js?render=explicit";

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

  return { container: <div ref={containerRef} style={{ display: "contents" }} />, execute };
}
