import cx from "classnames";
import * as React from "react";

import { Icon } from "$app/components/Icons";
import { IconOption } from "./types";

interface IconSelectorProps {
  value: string | null;
  onChange: (iconValue: string) => void;
  options: IconOption[];
  disabled?: boolean;
}

export const IconSelector: React.FC<IconSelectorProps> = ({
  value,
  onChange,
  options,
  disabled = false
}) => {
  return (
    <div 
      className="w-full" 
      role="radiogroup" 
      aria-label="Choose an icon"
    >
      <div className="flex gap-2 overflow-x-auto py-1">
        {options.map((option) => {
          const isSelected = value === option.value;
          const iconName = option.value;
          
          return (
            <button
              key={option.value}
              type="button"
              role="radio"
              aria-checked={isSelected}
              className={cx(
                "button small",
                "w-10 h-10 flex items-center justify-center bg-white",
                {
                  "border-2 border-accent bg-accent-light": isSelected,
                  "border border-border hover:border-accent": !isSelected
                }
              )}
              onClick={() => onChange(option.value)}
              disabled={disabled}
              style={{ padding: '8px' }}
            >
              <Icon name={iconName as any} className="w-5 h-5" />
            </button>
          );
        })}
      </div>
    </div>
  );
};