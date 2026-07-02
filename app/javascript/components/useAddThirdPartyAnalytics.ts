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
  iframe.classList.add("hidden");
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

// Profile-page variant: the profile has no product, so the seller's universal
// ("all products", location "all") snippets load through the username-based
// endpoint instead of the permalink-based one.
type ProfileOptions = { username: string };

export function useAddProfileThirdPartyAnalytics() {
  const { thirdPartyAnalyticsDomain } = useDomains();

  return (options: ProfileOptions) => addProfileThirdPartyAnalytics({ ...options, domain: thirdPartyAnalyticsDomain });
}

export function addProfileThirdPartyAnalytics({ domain, username }: ProfileOptions & { domain: string }) {
  const iframe = document.createElement("iframe");
  iframe.classList.add("hidden");
  iframe.setAttribute("sandbox", "allow-scripts allow-same-origin");
  iframe.ariaLabel = "Third-party analytics";
  iframe.dataset.username = username;
  iframe.setAttribute("src", Routes.profile_third_party_analytics_url(username, { host: domain }));
  document.body.appendChild(iframe);
}
