import { is } from "ts-safe-cast";

import { HeightMessage, isValidHost, onLoad, parseProductURL } from "./utils";

type TranslationsMessage = { type: "translations"; translations: Record<string, string> };

const script = document.querySelector<HTMLScriptElement>("script[src*='/js/gumroad.js']");
const customDomain = script ? new URL(script.src).host : undefined;

const overlay = document.createElement("div");
overlay.className = "overlay";
overlay.style.display = "none";

const overlayCloseButton = document.createElement("button");
overlayCloseButton.classList.add("close-button");
overlayCloseButton.innerHTML = '<span class="icon icon-x"></span>';
overlay.appendChild(overlayCloseButton);

const overlayIframe = document.createElement("iframe");
overlay.appendChild(overlayIframe);

const progressbar = document.createElement("div");
progressbar.setAttribute("role", "progressbar");
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
