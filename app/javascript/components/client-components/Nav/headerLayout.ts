// The header nav is on trial in several layouts. `?header=<name>` picks one and the choice is
// kept for the tab, so the layouts can be compared on real pages before one is kept.
export const HEADER_LAYOUTS = ["subnav", "subnav-centered", "subnav-light", "search-left", "bar"] as const;
export type HeaderLayout = (typeof HEADER_LAYOUTS)[number];

const STORAGE_KEY = "dashboard:header-layout";
const DEFAULT_LAYOUT: HeaderLayout = "subnav";
const isLayout = (value: string | null): value is HeaderLayout => HEADER_LAYOUTS.some((layout) => layout === value);

export const currentHeaderLayout = (): HeaderLayout => {
  if (typeof window === "undefined") return DEFAULT_LAYOUT;
  try {
    const requested = new URLSearchParams(window.location.search).get("header");
    if (isLayout(requested)) window.sessionStorage.setItem(STORAGE_KEY, requested);
    const stored = window.sessionStorage.getItem(STORAGE_KEY);
    return isLayout(stored) ? stored : DEFAULT_LAYOUT;
  } catch {
    // Storage can be blocked; the default layout still works.
    return DEFAULT_LAYOUT;
  }
};

// The page subtracts this from viewport-tall panes: one 4rem row, plus a 3rem row of links under it.
export const headerHeightClass = (layout: HeaderLayout) =>
  layout === "bar" ? "lg:[--dashboard-header-height:4rem]" : "lg:[--dashboard-header-height:7rem]";
