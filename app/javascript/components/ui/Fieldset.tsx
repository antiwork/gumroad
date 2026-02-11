import { cva } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

export type FieldsetState = "default" | "success" | "danger" | "warning" | "info";

const FieldsetContext = React.createContext<{ state: FieldsetState }>({ state: "default" });

export const useFieldset = () => React.useContext(FieldsetContext);

export const stateBorderStyles: Record<FieldsetState, string> = {
  default: "",
  success: "border-success",
  danger: "border-danger",
  warning: "border-warning",
  info: "border-info",
};

const fieldsetStyles = "flex flex-col border-none gap-2 [&[role=group]_label_input]:ml-auto";

export const Fieldset = React.forwardRef<
  HTMLFieldSetElement,
  React.FieldsetHTMLAttributes<HTMLFieldSetElement> & { state?: FieldsetState | undefined }
>(({ className, state, children, ...props }, ref) => {
  const contextValue = React.useMemo(() => ({ state: state ?? "default" }), [state]);
  return (
    <FieldsetContext.Provider value={contextValue}>
      <fieldset ref={ref} className={classNames(fieldsetStyles, className)} {...props}>
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
      "relative mb-2 flex w-full items-center justify-between text-base leading-[1.4] font-bold",
      "[&_a]:font-normal",
      className,
    )}
    {...props}
  >
    {children}
  </legend>
));
FieldsetTitle.displayName = "FieldsetTitle";

const descriptionVariants = cva("text-muted", {
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
