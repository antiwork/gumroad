import cx from "classnames";
import * as React from "react";

import { Icon } from "$app/components/Icons";
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
  previewLink?: (props: React.AriaAttributes & { children: React.ReactNode }) => React.ReactNode;
} & React.ComponentProps<"aside">) => {
  const uid = React.useId();
  return (
    <aside
      className={cx(
        "bg-filled sticky top-0 hidden h-screen flex-col gap-4 self-start overflow-auto p-6 lg:flex lg:border-l lg:border-border",
        className,
      )}
      aria-labelledby={`${uid}-title`}
      {...props}
    >
      <div className="flex items-start justify-between gap-4">
        <h2 id={`${uid}-title`}>Preview</h2>
        {previewLink ? (
          <WithTooltip tip="Preview">
            {previewLink({ "aria-label": "Preview", children: <Icon name="arrow-diagonal-up-right" /> })}
          </WithTooltip>
        ) : null}
      </div>
      {children}
    </aside>
  );
};
