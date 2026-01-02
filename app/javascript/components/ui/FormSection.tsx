import * as React from "react";

import { classNames } from "$app/utils/classNames";

export interface FormSectionProps extends React.HTMLProps<HTMLElement> {
  /** Set to true if this is the first section (removes top border/padding) */
  first?: boolean;
  /** Set to true if preceded by a separator (removes top border) */
  afterSeparator?: boolean;
}

/**
 * Form section component with responsive 2-column layout.
 *
 * On mobile: Single column stack with header above content.
 * On desktop (lg+): 2-column layout with header (25% width) on left,
 * content on right.
 *
 * Usage:
 * ```tsx
 * <form>
 *   <FormSection first>
 *     <header>
 *       <h2>Section Title</h2>
 *       <p>Description text</p>
 *     </header>
 *     <Fieldset>...</Fieldset>
 *     <Fieldset>...</Fieldset>
 *   </FormSection>
 * </form>
 * ```
 */
export const FormSection = React.forwardRef<HTMLElement, FormSectionProps>(
  ({ className, first, afterSeparator, children, ...props }, ref) => (
    <section
      ref={ref}
      className={classNames(
        "grid gap-8 border-t border-border py-12",
        first && "border-t-0 pt-0",
        afterSeparator && "border-t-0",
        "[&>header]:grid [&>header]:content-start [&>header]:gap-3",
        "lg:[&:not(.squished_&)]:grid-cols-[25%_1fr] lg:[&:not(.squished_&)]:gap-x-16 lg:[&:not(.squished_&)]:gap-y-0 lg:[&:not(.squished_&)]:pb-4",
        "lg:[&:not(.squished_&)>*]:col-[2] lg:[&:not(.squished_&)>*]:mb-8",
        "lg:[&:not(.squished_&)>header]:col-[1/2] lg:[&:not(.squished_&)>header]:row-[1/10]",
        className,
      )}
      {...props}
    >
      {children}
    </section>
  ),
);
FormSection.displayName = "FormSection";
