import { cva } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

export type FieldsetState = "default" | "success" | "danger" | "warning" | "info";

const FieldsetContext = React.createContext<{ state: FieldsetState }>({ state: "default" });

export const useFieldset = () => React.useContext(FieldsetContext);

// The ring doubles the edge: next to a grey field border, the colour alone is a hue change of about 1.4:1.
export const stateBorderStyles: Record<FieldsetState, string> = {
  default: "",
  success: "border-success ring-1 ring-success",
  danger: "border-danger ring-1 ring-danger",
  warning: "border-warning ring-1 ring-warning",
  info: "border-info ring-1 ring-info",
};

const fieldsetStyles = "flex flex-col border-none gap-2";

export const Fieldset = React.forwardRef<
  HTMLFieldSetElement,
  React.FieldsetHTMLAttributes<HTMLFieldSetElement> & { state?: FieldsetState | undefined }
>(({ className, state, children, ...props }, ref) => {
  const contextValue = React.useMemo(() => ({ state: state ?? "default" }), [state]);
  return (
    <FieldsetContext.Provider value={contextValue}>
      <fieldset
        ref={ref}
        className={classNames(fieldsetStyles, state && state !== "default" ? state : undefined, className)}
        {...props}
      >
        {children}
      </fieldset>
    </FieldsetContext.Provider>
  );
});
Fieldset.displayName = "Fieldset";

export const FieldsetTitle = React.forwardRef<
  HTMLLegendElement,
  { children: React.ReactNode } & React.HTMLAttributes<HTMLLegendElement>
>(({ className, children, ...props }, ref) => (
  <legend
    ref={ref}
    className={classNames(
      "relative mb-2 flex w-full items-center justify-between text-base leading-snug font-bold",
      "[&_a]:font-normal",
      className,
    )}
    {...props}
  >
    {children}
  </legend>
));
FieldsetTitle.displayName = "FieldsetTitle";

const descriptionVariants = cva("block text-muted", {
  variants: {
    state: {
      default: "",
      success: "text-success",
      danger: "text-danger",
      warning: "text-warning",
      info: "text-info",
    },
  },
});

export const FieldsetDescription = React.forwardRef<HTMLElement, React.HTMLAttributes<HTMLElement>>(
  ({ className, children, ...props }, ref) => {
    const { state } = useFieldset();
    return (
      <small ref={ref} className={classNames(descriptionVariants({ state }), className)} {...props}>
        {children}
      </small>
    );
  },
);
FieldsetDescription.displayName = "FieldsetDescription";
