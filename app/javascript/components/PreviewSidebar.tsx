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

// The frame every preview pane renders inside. The chrome matches the MEDIUM being
// previewed: web pages get a browser-style bar (centered title + URL like a tab and address
// bar, plus an open-in-new-tab arrow when the surface has a live page), while emails get an
// email-client-style header (From and Subject lines — emails land in inboxes, so a URL bar
// would be dishonest). Both variants share the same flat frame so they sit identically in
// the sidebar layout. The chrome IS the preview's identity strip — it replaces the old
// "Preview" heading and the separate open-in-new-tab button that used to sit next to it.
type PreviewChromeProps = { children: React.ReactNode } & (
  | {
      variant?: "web" | undefined;
      title: string;
      // The public URL of the previewed page, shown under the title (scheme stripped, like a
      // browser address bar). Omit it for previews with no meaningful public URL — never
      // fabricate one.
      url?: string | undefined;
      // Render prop for the open-in-new-tab button so each surface keeps its own navigation
      // behavior (plain link, or save-then-open). The chrome invokes it twice: once as a
      // compact icon button inside the desktop chrome bar, and once as a full labeled button
      // above the frame on mobile (a 32px icon-only target is too small and too cryptic for
      // touch). Spread `props` onto a Button or NavigationButton. Omit when there is nothing
      // to open.
      link?:
        | ((
            props: React.AriaAttributes & {
              size: "icon" | "default";
              className?: string;
              children: React.ReactNode;
            },
          ) => React.ReactNode)
        | undefined;
    }
  | {
      variant: "email";
      // The real sender the email goes out with, e.g. `Seller Name <noreply@customers.gumroad.com>`
      // — callers must derive this from the actual mailer configuration, not invent one.
      from: string;
      // The email's subject when the surface knows it client-side. Omit rather than guess —
      // the chrome then shows the From line alone.
      subject?: string | undefined;
    }
);

export const PreviewChrome = ({ children, ...props }: PreviewChromeProps) => (
  <>
    {/* On touch screens the compact in-bar arrow (32px, icon-only) is too small a target and
        too cryptic without its hover tooltip, so mobile gets the full labeled button in its
        own row above the frame instead — the same affordance the mobile preview pane had
        before the chrome existed. Desktop keeps the compact arrow inside the bar. */}
    {props.variant !== "email" && props.link ? (
      <div className="flex shrink-0 justify-end lg:hidden">
        {props.link({
          size: "default",
          children: (
            <>
              <ArrowUpRight className="size-5" />
              Open in new tab
            </>
          ),
        })}
      </div>
    ) : null}
    {/* `bg-background` (not a hardcoded white) so the chrome follows the dashboard's light/dark
        theme — the framed content paints its own background, but the chrome's rounded corners
        and the pre-load area would otherwise flash white in dark mode.

        `shrink-0` matters: the chrome renders as a flex item inside the sidebar's fixed-height
        flex column, and `overflow-hidden` (needed to clip children to the rounded corners)
        zeroes a flex item's automatic minimum size — without shrink-0 the chrome would compress
        to the viewport and silently clip tall previews instead of letting the sidebar scroll. */}
    <div className="flex shrink-0 flex-col overflow-hidden rounded border border-border bg-background">
      {props.variant === "email" ? (
        // Email headers read left-to-right like an email client, not centered like a browser
        // tab, and there is no open-in-new-tab arrow — an email has no URL to open.
        <div className="flex flex-col gap-0.5 border-b border-border bg-background px-4 py-2 text-sm">
          <div className="flex min-w-0 gap-2">
            <span className="shrink-0 text-muted">From</span>
            <span className="truncate">{props.from}</span>
          </div>
          {props.subject ? (
            <div className="flex min-w-0 gap-2">
              <span className="shrink-0 text-muted">Subject</span>
              <span className="truncate font-medium">{props.subject}</span>
            </div>
          ) : null}
        </div>
      ) : (
        <div className="relative border-b border-border bg-background px-10 py-2">
          <div className="min-w-0 text-center">
            <div className="truncate text-sm font-medium">{props.title}</div>
            {props.url ? (
              <div className="truncate text-xs text-muted">{props.url.replace(/^https?:\/\//u, "")}</div>
            ) : null}
          </div>
          {props.link ? (
            // Hidden below lg — mobile gets the labeled button row above the frame instead
            // (see the comment on the render prop).
            <div className="absolute inset-y-0 right-2 flex items-center max-lg:hidden">
              <WithTooltip tip="Open in new tab">
                {props.link({
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
      )}
      {children}
    </div>
  </>
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
