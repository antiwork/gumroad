import ClipboardJS from "clipboard";
import * as React from "react";

import { useRefToLatest } from "$app/components/useRefToLatest";
import { useRunOnce } from "$app/components/useRunOnce";
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

  useRunOnce(() => {
    const el = ref.current;

    if (el) {
      const clip = new ClipboardJS(el, { text: () => latestTextToCopyRef.current });
      clip.on("success", (event) => {
        setStatus("copied");

        event.clearSelection();
      });

      el.addEventListener("mouseleave", () => setStatus("initial"));
      return () => clip.destroy();
    }
  });

  return (
    <WithTooltip tip={status === "initial" ? copyTooltip : copiedTooltip} position={tooltipPosition}>
      <span ref={ref} className="contents" onClick={(e) => e.stopPropagation()}>
        {children}
        {/*
          Sighted users see the copy succeed because the tooltip flips to "Copied!". That swap is
          invisible to a screen reader: WithTooltip exposes the tip through aria-describedby, and
          changing the text of an already-referenced description is not an announced event.

          This live region carries the same confirmation as an announcement. It is polite so it
          waits for a pause rather than interrupting, and it is only populated after a successful
          copy so nothing is read out on render. Visually hidden, since the tooltip already covers
          the sighted case.
        */}
        <span role="status" aria-live="polite" className="sr-only">
          {status === "copied" ? copiedTooltip : ""}
        </span>
      </span>
    </WithTooltip>
  );
};
