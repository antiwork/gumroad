import * as React from "react";

import { classNames } from "$app/utils/classNames";

// `type` is omitted on purpose: a <button> without one defaults to `submit`, which makes it the
// default button of any enclosing <form> and fires it on Enter in that form's text inputs.
export type LinkButtonProps = Omit<React.ComponentPropsWithoutRef<"button">, "type">;

export const LinkButton = React.forwardRef<HTMLButtonElement, LinkButtonProps>(({ className, ...props }, ref) => (
  <button ref={ref} className={classNames("cursor-pointer underline all-unset", className)} {...props} type="button" />
));
LinkButton.displayName = "LinkButton";
