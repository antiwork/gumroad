import { request } from "$app/utils/request";

export const trackUserProductAction = async ({
  name,
  permalink,
  fromOverlay,
  wasRecommended,
  isModal = false,
}: {
  name: string;
  permalink: string;
  fromOverlay?: boolean;
  wasRecommended?: boolean;
  isModal?: boolean;
}) =>
  request({
    method: "POST",
    url: Routes.track_user_action_link_path(permalink),
    accept: "json",
    data: {
      event_name: name,
      referrer: getReferrer(),
      from_multi_overlay: fromOverlay ?? getIsOverlay(),
      was_product_recommended: wasRecommended ?? getWasRecommended(),
      view_url: window.location.pathname,
      is_modal: isModal,
    },
  });

export const trackUserActionEvent = (name: string) =>
  request({
    method: "POST",
    accept: "json",
    url: Routes.events_track_user_action_path(),
    data: {
      event_name: name,
      referrer: getReferrer(),
      plugins: getPlugins(),
      is_modal: window.location.search.includes("as_modal") && top !== self,
      from_multi_overlay: document.body.id === "overlay-page",
      source: new URLSearchParams(window.location.search).get("src"),
      view_url: window.location.pathname,
    },
  });

export const getReferrer = () =>
  new URLSearchParams(window.location.search).get("referrer") || document.referrer || "direct";
export const getIsOverlay = () => new URLSearchParams(window.location.search).get("overlay") === "true";
export const getWasRecommended = () => !!new URLSearchParams(window.location.search).get("recommended_by");
// eslint-disable-next-line @typescript-eslint/no-deprecated -- legacy code
export const getPlugins = () => [...navigator.plugins].map((plugin) => plugin.name).join();
