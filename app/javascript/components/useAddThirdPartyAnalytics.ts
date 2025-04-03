import { useDomains } from "./DomainSettings";

type Options = { permalink: string; location: "product" | "receipt"; purchaseId?: string };

export function useAddThirdPartyAnalytics() {
  const { thirdPartyAnalyticsDomain } = useDomains();

  return (options: Options) => addThirdPartyAnalytics({ ...options, domain: thirdPartyAnalyticsDomain });
}

export function addThirdPartyAnalytics({
  domain,
  permalink,
  location,
  purchaseId,
}: Options & {
  domain: string;
}) {
  const iframe = document.createElement("iframe");
  iframe.setAttribute("hidden", "true");
  iframe.setAttribute("sandbox", "allow-scripts allow-same-origin");
  iframe.ariaLabel = "Third-party analytics";
  iframe.dataset.permalink = permalink;
  iframe.setAttribute(
    "src",
    Routes.third_party_analytics_url(permalink, {
      host: domain,
      location,
      purchase_id: purchaseId,
    }),
  );
  document.body.appendChild(iframe);
}
