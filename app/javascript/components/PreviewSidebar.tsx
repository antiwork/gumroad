import { ArrowUpRight, Eye, Pencil } from "@boxicons/react";
import cx from "classnames";
import * as React from "react";
import { createPortal } from "react-dom";

import { Button } from "$app/components/Button";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { WithTooltip } from "$app/components/WithTooltip";

// On desktop the preview renders as a persistent sidebar next to the edit form. Below the lg
// breakpoint there is no room for both, so the page becomes two modes — Edit and Preview —
// switched by a floating segmented control. The mode state lives here so WithPreviewSidebar
// (which wraps the edit form) and PreviewSidebar (which owns the preview) stay in sync.
const MobilePreviewModeContext = React.createContext<{
  mode: "edit" | "preview";
  setMode: (mode: "edit" | "preview") => void;
} | null>(null);

export const WithPreviewSidebar = ({ children, className, ...props }: React.ComponentProps<"div">) => {
  const [mode, setMode] = React.useState<"edit" | "preview">("edit");
  const contextValue = React.useMemo(() => ({ mode, setMode }), [mode]);

  return (
    <MobilePreviewModeContext.Provider value={contextValue}>
      <div
        className={cx(
          "squished lg:grid lg:grid-cols-[1fr_30vw]",
          // Reserve space at the bottom on phones so the fixed Edit/Preview pill never covers
          // the last form field or button at max scroll (applies in both modes). The `!` is
          // needed because the `squished` utility's own `&:last-child { padding-bottom: 0 }`
          // rule has higher specificity and would zero this out again.
          "max-lg:pb-24!",
          // In mobile preview mode, hide everything except the preview pane and the mode
          // toggle (both marked with data-mobile-preview). The window scroll position is
          // deliberately kept when switching, so the preview lands roughly where you were
          // editing instead of jumping back to the top.
          mode === "preview" && "max-lg:[&>*:not([data-mobile-preview])]:hidden",
          className,
        )}
        {...props}
      >
        {children}
      </div>
    </MobilePreviewModeContext.Provider>
  );
};

// The browser-style frame every preview pane renders inside: a top bar with the previewed
// page's title and URL centered (like a browser tab + address bar) and, when the surface has
// a live page to open, an arrow on the right that opens it in a new tab. The chrome IS the
// preview's identity strip — it replaces the old "Preview" heading and the separate
// open-in-new-tab button that used to sit next to it.
export const PreviewChrome = ({
  title,
  url,
  link,
  children,
}: {
  title: string;
  // The public URL of the previewed page, shown under the title (scheme stripped, like a
  // browser address bar). Omit it for previews with no meaningful public URL (e.g. the
  // receipt preview or workflow emails) — never fabricate one.
  url?: string | undefined;
  // Render prop for the open-in-new-tab button so each surface keeps its own navigation
  // behavior (plain link, or save-then-open). The chrome passes the compact sizing and the
  // arrow icon so the button looks identical everywhere; spread `props` onto a Button or
  // NavigationButton. Omit when there is nothing to open.
  link?:
    | ((
        props: React.AriaAttributes & { size: "icon"; className: string; children: React.ReactNode },
      ) => React.ReactNode)
    | undefined;
  children: React.ReactNode;
}) => (
  // `bg-background` (not a hardcoded white) so the chrome follows the dashboard's light/dark
  // theme — the framed content paints its own background, but the chrome's rounded corners
  // and the pre-load area would otherwise flash white in dark mode.
  //
  // `shrink-0` matters: the chrome renders as a flex item inside the sidebar's fixed-height
  // flex column, and `overflow-hidden` (needed to clip children to the rounded corners)
  // zeroes a flex item's automatic minimum size — without shrink-0 the chrome would compress
  // to the viewport and silently clip tall previews instead of letting the sidebar scroll.
  <div className="flex shrink-0 flex-col overflow-hidden rounded border border-border bg-background">
    <div className="relative border-b border-border bg-background px-10 py-2">
      <div className="min-w-0 text-center">
        <div className="truncate text-sm font-medium">{title}</div>
        {url ? <div className="truncate text-xs text-muted">{url.replace(/^https?:\/\//u, "")}</div> : null}
      </div>
      {link ? (
        <div className="absolute inset-y-0 right-2 flex items-center">
          <WithTooltip tip="Open in new tab">
            {link({
              "aria-label": "Open in new tab",
              size: "icon",
              // The default icon size (size-12) dwarfs the slim chrome bar — shrink to a
              // compact 32px hit target that fits inside it.
              className: "size-8",
              children: <ArrowUpRight className="size-4" />,
            })}
          </WithTooltip>
        </div>
      ) : null}
    </div>
    {children}
  </div>
);

export const PreviewSidebar = ({
  children,
  className,
  ...props
}: {
  children: React.ReactNode;
} & React.ComponentProps<"aside">) => {
  const isDesktop = useIsAboveBreakpoint("lg");
  const modeContext = React.useContext(MobilePreviewModeContext);
  const mode = modeContext?.mode ?? "edit";

  return (
    <>
      <aside
        className={cx(
          "sticky top-0 hidden h-screen flex-col gap-4 self-start overflow-y-auto bg-background p-6 lg:flex lg:border-l lg:border-border",
          className,
        )}
        // The old visible "Preview" heading is gone (the PreviewChrome bar announces the
        // preview now), so the region needs an accessible name for screen readers.
        aria-label="Preview"
        {...props}
      >
        {children}
      </aside>
      {/* The desktop sidebar above is display:none below lg, which used to mean mobile sellers
          had NO way to see the preview at all (real support tickets). Below lg the page instead
          gets an Edit / Preview mode toggle, and this pane renders the same live preview inline
          when Preview mode is active. */}
      {!isDesktop && modeContext ? (
        <>
          {mode === "preview" ? (
            <section data-mobile-preview aria-label="Preview" className="flex flex-col gap-4 p-4 pb-24 lg:hidden">
              {/* The children render their own PreviewChrome, whose arrow button covers the
                  open-in-new-tab affordance on mobile too — no separate button row needed. */}
              {children}
            </section>
          ) : null}
          {/* Portaled to <body>: the page's <main> scroller uses [contain:paint], which turns it
              into the containing block for position:fixed descendants — a pill rendered inline
              here would scroll away with the form instead of staying pinned to the viewport. */}
          {createPortal(
            <div
              className="fixed inset-x-0 z-[9] flex justify-center lg:hidden"
              style={{ bottom: "calc(1rem + env(safe-area-inset-bottom))" }}
            >
              <div
                role="tablist"
                aria-label="Edit or preview"
                className="flex gap-1 rounded-full border border-border bg-background p-1"
              >
                <Button
                  role="tab"
                  aria-selected={mode === "edit"}
                  color={mode === "edit" ? "primary" : undefined}
                  size="sm"
                  className={cx("rounded-full", mode !== "edit" && "border-transparent")}
                  onClick={() => modeContext.setMode("edit")}
                >
                  <Pencil className="size-4" />
                  Edit
                </Button>
                <Button
                  role="tab"
                  aria-selected={mode === "preview"}
                  color={mode === "preview" ? "primary" : undefined}
                  size="sm"
                  className={cx("rounded-full", mode !== "preview" && "border-transparent")}
                  onClick={() => modeContext.setMode("preview")}
                >
                  <Eye className="size-4" />
                  Preview
                </Button>
              </div>
            </div>,
            document.body,
          )}
        </>
      ) : null}
    </>
  );
};
