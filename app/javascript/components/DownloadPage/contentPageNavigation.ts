// A buyer reading a multi-page product (a course) keeps their place in two places: the URL
// (`?page=<page_id>`) and the purchase. The URL is what a refresh, a bookmark, a shared link or a
// back/forward jump reads first, because it is both the most recent thing the buyer did and the
// only copy that survives the save request failing on the way to the server. The saved value stays
// as the fallback for a buyer arriving from a receipt or library link that carries no page.
export const CONTENT_PAGE_QUERY_PARAM = "page";

type ContentPageLike = { page_id: string };

export const indexOfPageId = (pages: ContentPageLike[], pageId: string | null) => {
  if (!pageId) return -1;
  return pages.findIndex((page) => page.page_id === pageId);
};

// An id that no longer belongs to a page (the seller deleted or replaced it) falls through to the
// saved page instead of dropping the buyer on the first page of the course.
export const initialContentPageIndex = (pages: ContentPageLike[], url: URL, lastPageId: string | null) => {
  const fromUrl = indexOfPageId(pages, url.searchParams.get(CONTENT_PAGE_QUERY_PARAM));
  if (fromUrl >= 0) return fromUrl;

  const saved = indexOfPageId(pages, lastPageId);
  return saved >= 0 ? saved : 0;
};

export const urlWithContentPage = (url: URL, pageId: string) => {
  const next = new URL(url.toString());
  next.searchParams.set(CONTENT_PAGE_QUERY_PARAM, pageId);
  return next.toString();
};

const SCROLL_MARGIN_PX = 24;

// Scrolls the page list itself, never the window: the list is independently scrollable beside the
// reading pane, so `Element#scrollIntoView` would drag the lesson the buyer is reading along with
// it whenever the list is not the nearest scroll container.
export const scrollWithinScrollableAncestor = (element: HTMLElement) => {
  let container = element.parentElement;
  while (container) {
    const style = window.getComputedStyle(container);
    const scrolls =
      (style.overflowY === "auto" || style.overflowY === "scroll") &&
      container.scrollHeight > container.clientHeight + 1;
    if (scrolls) break;
    container = container.parentElement;
  }
  if (!container) return false;

  const listRect = container.getBoundingClientRect();
  const itemRect = element.getBoundingClientRect();
  if (itemRect.top >= listRect.top && itemRect.bottom <= listRect.bottom) return false;

  container.scrollTop += itemRect.top - listRect.top - SCROLL_MARGIN_PX;
  return true;
};
