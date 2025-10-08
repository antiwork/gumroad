import { useUnreadConversationsCount } from "@helperai/react";
import cx from "classnames";
import * as React from "react";

export const UnreadTicketsBadge = ({ className }: { className?: string }) => {
  const { data } = useUnreadConversationsCount();
  if (!data?.count) return null;
  return (
    <span
      className={cx(
        "bg-pink inline-flex h-5 w-5 items-center justify-center rounded-full border border-black text-xs text-black",
        className,
      )}
    >
      {data.count > 9 ? "9+" : data.count}
    </span>
  );
};
