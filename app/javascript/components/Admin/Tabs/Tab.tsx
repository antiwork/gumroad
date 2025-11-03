import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

type TabProps = {
  children: React.ReactNode;
  isSelected?: boolean;
  onClick?: () => void;
  ariaControls?: string;
  className?: string;
  asChild?: boolean;
};

const Tab = ({ children, isSelected, onClick = () => {}, ariaControls, className, asChild = false }: TabProps) => {
  const Component = asChild ? Slot : "div";

  return (
    <Component
      role="tab"
      className={classNames(
        "opacity-70",
        "dark:font-bold dark:text-white/70",
        "rounded border border-border",
        "hover:-translate-x-1 hover:-translate-y-1 hover:shadow-[0.25rem_0.25rem_0_currentColor]",
        "transition-[opacity,transform] duration-200 ease-out",
        {
          "bg-white font-bold opacity-100 dark:bg-transparent dark:text-white": isSelected,
        },
        className,
      )}
      aria-selected={isSelected}
      aria-controls={ariaControls}
      onClick={onClick}
    >
      {children}
    </Component>
  );
};

export default Tab;
