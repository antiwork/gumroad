import { ArrowDown } from "@boxicons/react";
import * as React from "react";

export const DEFAULT_FORM_ELEMENT_HEIGHT_IN_PX = 48; // same as the `$form-element-height` design system variable

export const ScrollToBottomButton = ({
  hasUnreadMessages,
  onClick,
  chatMessageInputHeight = 0,
}: {
  hasUnreadMessages: boolean;
  onClick: () => void;
  chatMessageInputHeight?: number;
}) => {
  const additionalBottom = Math.max(0, chatMessageInputHeight - DEFAULT_FORM_ELEMENT_HEIGHT_IN_PX);

  return (
    <div
      className="fixed left-1/2 z-10 -translate-x-1/2 transition-all duration-300 max-lg:left-1/2 lg:left-[calc(50%+var(--main-stack-width)/3)]"
      style={{ bottom: `calc(var(--form-element-height) + var(--spacer-6) + ${additionalBottom}px)` }}
    >
      <button
        aria-label="Scroll to bottom"
        onClick={onClick}
        className="flex cursor-pointer items-center justify-center gap-1 overflow-hidden rounded-full border border-solid all-unset bg-black px-3 py-1.5 text-xs font-bold text-white hover:border-black hover:bg-pink hover:text-black dark:border-black dark:bg-pink dark:text-black dark:hover:bg-pink"
      >
        <ArrowDown className="size-5" />
        <span>{hasUnreadMessages ? "New messages" : "Latest messages"}</span>
      </button>
    </div>
  );
};
