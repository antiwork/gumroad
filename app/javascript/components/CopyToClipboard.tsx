import ClipboardJS from "clipboard";
import * as React from "react";

import { useRefToLatest } from "$app/components/useRefToLatest";
import { WithTooltip, Position as TooltipPosition } from "$app/components/WithTooltip";

type CopyToClipboardProps = {
  text: string;
  copyTooltip?: string;
  copiedTooltip?: string;
  children: React.ReactElement;
  tooltipPosition?: TooltipPosition;
};
export const CopyToClipboard = ({
  text,
  copyTooltip = "Copy to Clipboard",
  copiedTooltip = "Copied!",
  children,
  tooltipPosition,
}: CopyToClipboardProps) => {
  const [status, setStatus] = React.useState<"initial" | "copied">("initial");
  const ref = React.useRef<HTMLElement | null>(null);
  const latestTextToCopyRef = useRefToLatest(text);

  // Deliberately a plain useEffect rather than useRunOnce: this sets up a ClipboardJS instance and
  // a DOM listener that both have to be torn down when the component unmounts, and useRunOnce
  // ignores a returned cleanup function. The effect body is still only ever run once per mount
  // because it depends on nothing that changes — the copied text is read through a ref so that
  // updating it does not rebuild the ClipboardJS instance.
  React.useEffect(() => {
    const el = ref.current;
    if (!el) return;

    const clip = new ClipboardJS(el, { text: () => latestTextToCopyRef.current });
    clip.on("success", (event) => {
      setStatus("copied");

      event.clearSelection();
    });

    const resetStatus = () => setStatus("initial");
    el.addEventListener("mouseleave", resetStatus);

    return () => {
      clip.destroy();
      el.removeEventListener("mouseleave", resetStatus);
    };
  }, []);

  return (
    <WithTooltip tip={status === "initial" ? copyTooltip : copiedTooltip} position={tooltipPosition}>
      <span ref={ref} className="contents" onClick={(e) => e.stopPropagation()}>
        {children}
      </span>
      {/*
        Sighted users learn the copy succeeded from the tooltip flipping to copiedTooltip. That text
        reaches assistive tech through aria-describedby, and changing the content of an
        already-referenced description is not an announced event, so screen-reader users got no
        confirmation at all. This live region carries the same wording as a real announcement. It is
        empty until a copy succeeds so nothing is read out on render.
      */}
      <span role="status" aria-live="polite" className="sr-only">
        {status === "copied" ? copiedTooltip : ""}
      </span>
    </WithTooltip>
  );
};
