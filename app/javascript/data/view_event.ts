import { getIsOverlay, getPlugins, getReferrer, getWasRecommended } from "$app/data/user_action_event";
import { request } from "$app/utils/request";

export const incrementProductViews = ({
  permalink,
  recommendedBy,
}: {
  permalink: string;
  recommendedBy?: string | null;
}) =>
  request({
    method: "POST",
    url: Routes.increment_views_link_path(permalink),
    accept: "json",
    data: {
      is_modal: window.location.search.includes("as_modal") && top !== self,
      plugins: getPlugins(),
      referrer: getReferrer(),
      got_cookies: navigator.cookieEnabled,
      from_multi_overlay: getIsOverlay(),
      source: new URLSearchParams(window.location.search).get("src"),
      was_product_recommended: getWasRecommended(),
      recommended_by: recommendedBy,
      window_location: window.location.toString(),
      view_url: window.location.pathname,
    },
  });

export const incrementPostViews = ({ postId }: { postId: string }) =>
  request({
    method: "POST",
    url: Routes.increment_post_views_path(postId),
    accept: "json",
    data: {
      referrer: getReferrer(),
      source: new URLSearchParams(window.location.search).get("src"),
      window_location: window.location.toString(),
      view_url: window.location.pathname,
    },
  });
