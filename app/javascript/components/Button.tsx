import cx from "classnames";
import * as React from "react";
import { is } from "ts-safe-cast";

import { assert } from "$app/utils/assert";

import { ButtonColor, buttonColors } from "$app/components/design";

type ButtonVariation = {
  disabled?: boolean | undefined;
  color?: ButtonColor | undefined;
  outline?: boolean | undefined;
  small?: boolean | undefined;
};

export type ButtonProps = React.ComponentPropsWithoutRef<"button"> & ButtonVariation;
export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>((props, ref) => {
  useValidateClassName(props.className);

  const { className, ...rest } = extractButtonClassNameFromProps(props);

  return <button className={cx("button", className)} ref={ref} disabled={props.disabled} type="button" {...rest} />;
});
Button.displayName = "Button";

type NavigationButtonProps = React.ComponentPropsWithoutRef<"a"> & ButtonVariation;
export const NavigationButton = React.forwardRef<HTMLAnchorElement, NavigationButtonProps>((props, ref) => {
  useValidateClassName(props.className);

  const { className, disabled, ...rest } = extractButtonClassNameFromProps(props);

  return (
    <a
      className={cx(className, "button")}
      ref={ref}
      inert={disabled}
      {...rest}
      onClick={(evt) => {
        if (props.onClick == null) return;

        if (props.href == null || props.href === "#") evt.preventDefault();

        props.onClick(evt);

        evt.stopPropagation();
      }}
    />
  );
});
NavigationButton.displayName = "NavigationButton";

// Logs warnings whenever `className` changes, instead of on every render
const useValidateClassName = (className: string | undefined) => {
  if (process.env.NODE_ENV === "production") return;

  React.useEffect(() => validateClassName(className), [className]);
};

// Display warnings when trying to use color/variant/size as class name, suggesting a prop to use instead
const validateClassName = (className: string | undefined) => {
  if (process.env.NODE_ENV === "production") return;

  if (className == null) return;

  const classes = className.split(" ");

  classes.forEach((cls) => {
    assert(cls !== "button", `Button: Using '${cls}' as 'className' prop is unnecessary`);
    assert(!is<ButtonColor>(cls), `Button: Instead of using '${cls}' as a class, use the 'color="${cls}"' prop`);
    assert(
      !buttonColors.some((color) => cls === `outline-${color}`),
      `Button: Instead of using '${cls}' as a class, use the 'color="${cls.replace(
        "outline-",
        "",
      )}" and the 'outline' prop`,
    );
    assert(cls !== "small", `Button: Instead of using '${cls}' as a class, use the 'small' prop`);
  });
};

const extractButtonClassNameFromProps = <ElementProps extends ButtonProps | NavigationButtonProps>(
  props: ElementProps,
): { className: string } & Omit<ElementProps, "className" | "color" | "outline" | "small"> => {
  const { className, color, outline, small, ...rest } = props;

  const classNames = cx({ small }, color != null ? (outline ? `outline-${color}` : color) : null, className);

  return { className: classNames, ...rest };
};
