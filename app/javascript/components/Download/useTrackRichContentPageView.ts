import { useEffect, useRef } from "react";
import { request } from "$app/utils/request";

export const useTrackRichContentPageView = ({
  pageId,
  urlRedirectId,
  enabled = true,
}: {
  pageId: string;
  urlRedirectId: string;
  enabled?: boolean;
}) => {
  const hasTrackedRef = useRef(false);

  useEffect(() => {
    if (!enabled || hasTrackedRef.current || !pageId || !urlRedirectId) {
      return;
    }

    const trackPageView = async () => {
      try {
        await request({
          url: Routes.rich_content_page_views_path(),
          method: "POST",
          accept: "json",
          body: {
            page_id: pageId,
            url_redirect_id: urlRedirectId,
          },
        });
        hasTrackedRef.current = true;
      } catch (error) {
        // eslint-disable-next-line no-console
        console.error("Failed to track page view:", error);
      }
    };

    void trackPageView();
  }, [pageId, urlRedirectId, enabled]);
};
