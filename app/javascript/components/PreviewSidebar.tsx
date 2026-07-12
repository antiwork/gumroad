import { ArrowUpRight, Eye, X } from "@boxicons/react";
import { Close as DialogClose } from "@radix-ui/react-dialog";
import cx from "classnames";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Sheet } from "$app/components/ui/Sheet";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { WithTooltip } from "$app/components/WithTooltip";

export const WithPreviewSidebar = ({ children, className, ...props }: React.ComponentProps<"div">) => (
  <div className={cx("squished lg:grid lg:grid-cols-[1fr_30vw]", className)} {...props}>
    {children}
  </div>
);

export const PreviewSidebar = ({
  children,
  className,
  previewLink,
  ...props
}: {
  children: React.ReactNode;
  // `size` lets each rendering context pick the button shape: the desktop sidebar keeps its
  // compact icon button, while the mobile sheet asks for a regular button with a visible text
  // label (icon-only buttons aren't intuitive enough on their own).
  previewLink?: (
    props: React.AriaAttributes & { children: React.ReactNode; size?: "default" | "icon" },
  ) => React.ReactNode;
} & React.ComponentProps<"aside">) => {
  const uid = React.useId();
  const isDesktop = useIsAboveBreakpoint("lg");
  const [mobilePreviewOpen, setMobilePreviewOpen] = React.useState(false);

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
      {/* On narrow screens the sidebar above is hidden entirely, which used to mean mobile
          sellers had NO way to see the preview (support tickets: "there's no preview button").
          Give them the same live preview in a full-screen sheet, opened from a floating button. */}
      {!isDesktop ? (
        <>
          <div className="fixed right-4 z-30 lg:hidden" style={{ bottom: "calc(1rem + env(safe-area-inset-bottom))" }}>
            <Button color="primary" onClick={() => setMobilePreviewOpen(true)}>
              <Eye className="size-5" />
              Preview
            </Button>
          </div>
          <Sheet modal open={mobilePreviewOpen} onOpenChange={setMobilePreviewOpen} className="lg:hidden">
            {/* Buttons here carry visible text labels rather than bare icons — icon-only
                buttons aren't intuitive, especially for the mobile sellers this sheet serves. */}
            <div className="flex items-center gap-4">
              <h2>Preview</h2>
              {previewLink
                ? previewLink({
                    size: "default",
                    children: (
                      <>
                        <ArrowUpRight className="size-5" />
                        Open in new tab
                      </>
                    ),
                  })
                : null}
              <DialogClose asChild>
                <Button className="ml-auto">
                  <X className="size-5" />
                  Close
                </Button>
              </DialogClose>
            </div>
            <div className="flex flex-1 flex-col gap-4">{children}</div>
          </Sheet>
        </>
      ) : null}
    </>
  );
};
