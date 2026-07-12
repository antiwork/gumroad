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

export const PreviewSidebar = ({
  children,
  className,
  previewLink,
  ...props
}: {
  children: React.ReactNode;
  // `size` lets each rendering context pick the button shape: the desktop sidebar keeps its
  // compact icon button, while the mobile preview pane asks for a regular button with a
  // visible text label (icon-only buttons aren't intuitive enough on their own).
  previewLink?: (
    props: React.AriaAttributes & { children: React.ReactNode; size?: "default" | "icon" },
  ) => React.ReactNode;
} & React.ComponentProps<"aside">) => {
  const uid = React.useId();
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
        aria-labelledby={`${uid}-title`}
        {...props}
      >
        <div className="flex items-start justify-between gap-4">
          <h2 id={`${uid}-title`}>Preview</h2>
          {previewLink ? (
            <WithTooltip tip="Preview">
              {previewLink({ "aria-label": "Preview", children: <ArrowUpRight className="size-5" /> })}
            </WithTooltip>
          ) : null}
        </div>
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
              {previewLink ? (
                <div className="flex justify-end">
                  {previewLink({
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
