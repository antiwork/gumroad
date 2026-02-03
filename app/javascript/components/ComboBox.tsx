import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useOnOutsideClick } from "$app/components/useOnOutsideClick";

type Props<Option> = {
  input: (props: React.HTMLAttributes<HTMLElement>) => React.ReactElement;
  editable?: boolean;
  disabled?: boolean;
  multiple?: boolean;
  open?: boolean | undefined;
  onToggle?: (open: boolean) => void;
  options: Option[];
  option: (
    item: Option,
    props: React.HTMLAttributes<HTMLElement> & { ref: React.RefCallback<HTMLElement> },
    index: number,
  ) => React.ReactElement;
  maxHeight?: string | number;
};

export const ComboBox = <Option extends unknown>({
  input,
  editable,
  disabled,
  multiple,
  open: openProp,
  onToggle,
  options,
  option,
  className,
  maxHeight,
  ...rest
}: Props<Option> & Omit<React.HTMLAttributes<HTMLDivElement>, keyof Props<Option>>) => {
  const [open, setOpen] = React.useState(openProp ?? false);
  const [focusedOptionIndex, setFocusedOptionIndex] = React.useState<number | null>(null);
  const [inputFocused, setInputFocused] = React.useState(false);
  const uid = React.useId();

  if (openProp !== undefined && open !== openProp) setOpen(openProp);

  const toggle = (newOpen: boolean) => {
    if (openProp === undefined) setOpen(newOpen);
    if (newOpen !== open) onToggle?.(newOpen);
  };

  const selfRef = React.useRef<HTMLDivElement>(null);
  useOnOutsideClick([selfRef], () => {
    toggle(false);
    setFocusedOptionIndex(null);
  });

  const itemRefs: (HTMLElement | null)[] = [];

  const moveCursor = (from: number, by: number) => {
    let i = from;
    do {
      i = (from + by) % options.length;
      if (!itemRefs[i]?.inert) {
        setFocusedOptionIndex(i);
        break;
      }
    } while (i !== from);
  };

  useGlobalEventListener("keyup", (e) => {
    if (inputFocused && e.key === " ") {
      toggle(!open);
    }

    if (!open) return;

    switch (e.key) {
      case "Enter":
        if (focusedOptionIndex !== null) {
          itemRefs[focusedOptionIndex]?.click();
        }
        toggle(false);
        setFocusedOptionIndex(null);
        break;
      case "Escape":
        toggle(false);
        setFocusedOptionIndex(null);
        break;
      case "ArrowDown": {
        moveCursor(focusedOptionIndex ?? -1, 1);
        break;
      }
      case "ArrowUp": {
        moveCursor(focusedOptionIndex ?? options.length, -1);
        break;
      }
    }
  });

  return (
    <div ref={selfRef} className={classNames("relative", className)} {...rest}>
      {input({
        role: "combobox",
        "aria-expanded": open,
        "aria-controls": uid,
        inert: disabled,
        "aria-activedescendant": focusedOptionIndex ? `${uid}-${focusedOptionIndex}` : undefined,
        ...(editable
          ? {
              onFocus: () => toggle(true),
              onBlur: () => toggle(false),
            }
          : {
              onClick: () => toggle(!open),
              onFocus: () => setInputFocused(true),
              onBlur: () => setInputFocused(false),
              tabIndex: 0,
            }),
      })}
      <div hidden={!open} onMouseDown={(e) => e.preventDefault()}>
        <datalist
          id={uid}
          onMouseOut={() => setFocusedOptionIndex(null)}
          aria-multiselectable={multiple}
          style={maxHeight ? { maxHeight } : undefined}
          className={classNames(
            "absolute top-full left-0 z-10 block w-full overflow-auto rounded-b border border-t-0 border-border bg-background py-2 shadow",
          )}
        >
          {options.map((item, index) => (
            <React.Fragment key={index}>
              {option(
                item,
                {
                  ref: (node) => (itemRefs[index] = node),
                  role: "option",
                  id: `${uid}-${index}`,
                  className: classNames(
                    "px-4 py-2 cursor-pointer flex items-center",
                    focusedOptionIndex === index && "bg-primary text-primary-foreground [&_*]:text-inherit",
                  ),
                  onMouseOver: () => setFocusedOptionIndex(index),
                  onClick: () => {
                    setFocusedOptionIndex(null);
                    toggle(false);
                  },
                },
                index,
              )}
            </React.Fragment>
          ))}
        </datalist>
      </div>
    </div>
  );
};
