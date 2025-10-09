import cx from "classnames";
import React from "react";

import { useUserAgentInfo } from "$app/components/UserAgent";

export const Separator = ({
  text,
  id,
  type,
  showDividerLine = true,
  ...rest
}: {
  text: string;
  type: "date" | "unread";
  showDividerLine?: boolean;
} & React.HTMLAttributes<HTMLDivElement>) => (
  <div
    className={cx("flex items-center", {
      "justify-center": !showDividerLine,
      "pt-6": type === "date" && !showDividerLine,
    })}
    data-id={id}
    data-separator={type}
    {...rest}
  >
    {showDividerLine ? (
      <div
        className={cx("grow border-t", {
          "border-gray-200 dark:border-pink": type === "unread",
          "border-black/10 dark:border-[rgb(var(--parent-color)/var(--border-alpha))]": type === "date",
        })}
      ></div>
    ) : null}
    <span
      className={cx("shrink rounded-full border px-3 py-1.5 text-xs font-bold", {
        "border-gray-200 bg-black text-white dark:border-black dark:bg-pink dark:text-black": type === "unread",
        "border-black/10 bg-white text-black dark:border-[rgb(var(--parent-color)/var(--border-alpha))] dark:bg-black dark:text-(--primary)":
          type === "date",
      })}
    >
      {text}
    </span>
    {showDividerLine ? (
      <div
        className={cx("grow border-t", {
          "border-gray-200 dark:border-pink": type === "unread",
          "border-black/10 dark:border-[rgb(var(--parent-color)/var(--border-alpha))]": type === "date",
        })}
      ></div>
    ) : null}
  </div>
);

export const DateSeparator = ({
  date,
  showDividerLine = true,
  ...rest
}: {
  date: string;
  showDividerLine?: boolean;
} & React.HTMLAttributes<HTMLDivElement>) => {
  const userAgentInfo = useUserAgentInfo();
  const messageDate = new Date(date);
  const today = new Date();
  const yesterday = new Date();
  yesterday.setDate(today.getDate() - 1);

  let dateHeader;
  if (messageDate.toLocaleDateString() === today.toLocaleDateString()) {
    dateHeader = "Today";
  } else if (messageDate.toLocaleDateString() === yesterday.toLocaleDateString()) {
    dateHeader = "Yesterday";
  } else {
    dateHeader = messageDate.toLocaleDateString(userAgentInfo.locale, {
      weekday: "long" as const,
      day: "2-digit" as const,
      month: "long" as const,
      year: messageDate.getFullYear() === today.getFullYear() ? undefined : ("numeric" as const),
    });
  }

  return <Separator type="date" text={dateHeader} showDividerLine={showDividerLine} {...rest} />;
};

export const UnreadSeparator = ({ visible }: { visible: boolean }) => (
  <div className={cx("relative z-10 -mt-4 flex items-center", { invisible: !visible })}>
    <div className="absolute -top-1 left-0 h-full w-full">
      <Separator type="unread" text="Unread" id="unread-separator" />
    </div>
  </div>
);
