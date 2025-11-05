import cx from "classnames";
import * as React from "react";

import { Icon } from "$app/components/Icons";
import { WithTooltip } from "$app/components/WithTooltip";

export const WithPreviewSidebar = ({ children, className, ...props }: React.ComponentProps<"div">) => (
  <div className={cx("flex-1 lg:grid lg:grid-cols-[1fr_30vw]", className)} {...props}>
    {children}
  </div>
);

export const PreviewSidebar = ({
  children,
  className,
  title,
  previewLink,
  ...props
}: {
  children: React.ReactNode;
  title: React.ReactNode;
  previewLink?: (props: React.AriaAttributes & { children: React.ReactNode }) => React.ReactNode;
} & React.ComponentProps<"aside">) => {
  const uid = React.useId();
  return (
    <aside
      className={cx(
        "bg-filled relative hidden flex-col gap-4 overflow-auto p-6 md:flex lg:flex lg:w-[40vw] lg:border-l lg:border-border",
        className,
      )}
      aria-labelledby={`${uid}-title`}
      {...props}
    >
      <div className="flex items-start justify-between gap-4">
        <h2 id={`${uid}-title`}>{title}</h2>
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
