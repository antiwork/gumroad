import { is } from "ts-safe-cast";

import { HeightMessage, isValidHost, onLoad, parseProductURL } from "./utils";

type TranslationsMessage = { type: "translations"; translations: Record<string, string> };

const script = document.querySelector<HTMLScriptElement>("script[src*='/js/gumroad.js']");
const customDomain = script ? new URL(script.src).host : undefined;

const overlay = document.createElement("div");
overlay.className = "fixed inset-0 overflow-scroll bg-black/80";
overlay.style.display = "none";

const content = document.createElement("div");
content.className = "mx-auto max-w-product-page p-4 lg:px-8 lg:py-16";
overlay.appendChild(content);

const overlayCloseButton = document.createElement("button");
overlayCloseButton.className = "button filled fixed right-3 top-3";
overlayCloseButton.innerHTML = '<span class="icon icon-x"></span>';
overlay.appendChild(overlayCloseButton);

const overlayIframe = document.createElement("iframe");
overlayIframe.className = "w-full rounded-sm border-none";
content.appendChild(overlayIframe);

const progressbar = document.createElement("div");
progressbar.setAttribute("role", "progressbar");
progressbar.className = "fixed left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2";
progressbar.style.display = "none";

const registerButton = (button: HTMLAnchorElement) => {
  if (!!button.closest("[data-gumroad-ignore='true']") || !!button.closest(".gumroad-product-embed")) return;

  const url = parseProductURL(button.href, customDomain);
  if (!url) return;

  if (button.dataset.gumroadOverlayCheckout === "true") url.searchParams.set("wanted", "true");

  if (url.searchParams.get("wanted") === "true") {
    button.href = url.toString();
  } else {
    url.searchParams.set("overlay", "true");
    button.addEventListener("click", (evt) => {
      evt.preventDefault();
      progressbar.style.display = "";
      overlayIframe.src = url.toString();
    });
  }

  const logo = document.createElement("span");
  logo.className = "logo-full";
  button.appendChild(logo);
};

const registerChildrenButtons = (elt: Element | Document) => elt.querySelectorAll("a").forEach(registerButton);

onLoad(() => {
  const root = document.createElement("div");
  root.style.zIndex = "999999";
  root.style.position = "absolute";
  const shadowRoot = root.attachShadow({ mode: "open" });
  const link = document.createElement("link");
  link.setAttribute("rel", "stylesheet");
  link.setAttribute("href", script?.dataset.stylesUrl ?? "");
  link.setAttribute("crossorigin", "anonymous");
  shadowRoot.appendChild(link);
  const widget = document.createElement("div");
  widget.className = "widget";
  shadowRoot.appendChild(widget);
  widget.appendChild(progressbar);
  widget.appendChild(overlay);
  document.body.appendChild(root);

  registerChildrenButtons(document);
  new MutationObserver((mutationList) => {
    for (const mutation of mutationList) {
      mutation.addedNodes.forEach((addedNode) => {
        if (addedNode instanceof HTMLAnchorElement) registerButton(addedNode);
        else if (addedNode instanceof Element) registerChildrenButtons(addedNode);
      });
    }
  }).observe(document, { subtree: true, childList: true });
});

overlay.addEventListener("click", (evt) => {
  if (evt.target === overlayIframe) return;

  overlay.style.display = "none";
  document.body.style.overflow = "";
});

window.addEventListener("message", (evt) => {
  const url = new URL(evt.origin);

  if (evt.source !== overlayIframe.contentWindow || !isValidHost(url, customDomain)) return;

  if (is<{ type: "loaded" }>(evt.data)) {
    progressbar.style.display = "none";
    document.body.style.overflow = "hidden";
    overlay.style.display = "";
  } else if (is<HeightMessage>(evt.data)) {
    overlayIframe.style.height = `${evt.data.height}px`;
  } else if (is<TranslationsMessage>(evt.data)) {
    overlayCloseButton.ariaLabel = evt.data.translations.close || "";
  }
});
