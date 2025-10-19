import * as React from "react";

import { classNames } from "$app/utils/classNames";

type IconProps = {
  name: IconName;
} & React.JSX.IntrinsicElements["span"];
export const Icon = ({ name, className, ...props }: IconProps) => (
  <span className={classNames("icon", `icon-${name}`, className)} {...props} />
);
