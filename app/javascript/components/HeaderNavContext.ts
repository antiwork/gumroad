import * as React from "react";

// True on pages laid out under the dashboard's horizontal header (the dashboard_header_nav trial).
// A context, not the logged-in user: shared UI components also render on pages with no user.
export const HeaderNavContext = React.createContext(false);

// Inside a page header under the horizontal header, tabs are plain text with an underline, like
// the header's own links, in place of pills: on the actions' "row", or "stacked" under a title.
export const TextTabsContext = React.createContext<"row" | "stacked" | null>(null);

// The header marks the section being viewed, so a page header that repeats its name adds nothing.
const SECTION_TITLES = new Set([
  "Dashboard",
  "Products",
  "Sales",
  "Payouts",
  "Discover",
  "Profile",
  "Pages",
  "Collaborators",
  "Checkout",
  "Emails",
  "Workflows",
  "Analytics",
  "Affiliates",
  "Community",
  "Library",
  // A tab of Emails, which the header marks.
  "Subscribers",
]);
export const isSectionTitle = (title: React.ReactNode) => typeof title === "string" && SECTION_TITLES.has(title);
