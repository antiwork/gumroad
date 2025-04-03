import { is } from "ts-safe-cast";

import { HeightMessage, isValidHost, onLoad, parseProductURL } from "./utils";

const script = document.querySelector<HTMLScriptElement>("script[src*='/js/gumroad-embed.js']");
const customDomain = script ? new URL(script.src).host : undefined;

const embeds: HTMLIFrameElement[] = [];

const registerEmbed = (element: HTMLDivElement) => {
  let href = element.querySelector("a")?.href;
  if (element.dataset.gumroadProductId)
    href = `${process.env.PROTOCOL}://${process.env.DOMAIN}/l/${element.dataset.gumroadProductId}`;
  if (!href) return;
  const iframe = document.createElement("iframe");
  const url = parseProductURL(href, customDomain);
  if (!url) return;
  url.searchParams.set("embed", "true");
  const gumroadParams = new URLSearchParams(element.dataset.gumroadParams);
  for (const [key, value] of gumroadParams.entries()) url.searchParams.set(key, value);

  iframe.src = url.toString();
  iframe.style.border = "none";
  iframe.style.width = "100%";
  embeds.push(iframe);
  element.after(iframe);
  element.remove();
};

const EMBED_SELECTOR = "div.gumroad-product-embed";
const registerChildrenEmbeds = (elt: Element | Document) =>
  elt.querySelectorAll<HTMLDivElement>(EMBED_SELECTOR).forEach(registerEmbed);

onLoad(() => {
  registerChildrenEmbeds(document);
  new MutationObserver((mutationList) => {
    for (const mutation of mutationList) {
      mutation.addedNodes.forEach((addedNode) => {
        if (addedNode instanceof HTMLDivElement && addedNode.matches(EMBED_SELECTOR)) registerEmbed(addedNode);
        else if (addedNode instanceof Element) registerChildrenEmbeds(addedNode);
      });
    }
  }).observe(document, { subtree: true, childList: true });
});

window.addEventListener("message", (evt) => {
  const url = new URL(evt.origin);
  const iframe = embeds.find((embed) => embed.contentWindow === evt.source);
  if (!iframe || !isValidHost(url, customDomain)) return;

  if (is<HeightMessage>(evt.data)) iframe.style.height = `${evt.data.height}px`;
});
