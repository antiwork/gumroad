import cx from "classnames";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { assertDefined } from "$app/utils/assert";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Icon } from "$app/components/Icons";
import { Progress } from "$app/components/Progress";
import { showAlert } from "$app/components/server-components/Alert";
import { useRunOnce } from "$app/components/useRunOnce";
import { WithTooltip } from "$app/components/WithTooltip";

const useFetchStat = () => {
  const fetchStat = async ({ url }: { url: string }): Promise<string> => {
    try {
      const response = await request({
        method: "GET",
        url,
        accept: "json",
      });
      if (response.ok) {
        const responseData = cast<{ success: true; value: string } | { success: false; error?: string }>(
          await response.json(),
        );
        if (responseData.success) return responseData.value;
        throw new ResponseError(responseData.error);
      }
      throw new ResponseError();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
      return "-";
    }
  };

  return fetchStat;
};

export const Stats = ({
  title,
  description,
  value,
  className,
  url,
}: {
  title: React.ReactNode;
  description?: string;
  value?: string;
  className?: string;
  url?: string;
}) => {
  const [adjustedFontSize, setAdjustedFontSize] = React.useState<number | null>(null);
  const containerRef = React.useRef<HTMLDivElement | null>(null);
  const [valueText, setValueText] = React.useState(value ?? "");
  const fetchStat = useFetchStat();

  useRunOnce(() => {
    if (url) {
      fetchStat({ url })
        .then((newValue) => setValueText(newValue))
        .catch(() => setValueText("-"));
    }
  });

  React.useEffect(() => {
    const calculateFontSize = () => {
      if (!containerRef.current) return;
      const style = window.getComputedStyle(containerRef.current);
      const containerWidth = containerRef.current.getBoundingClientRect().width;
      document.fonts.ready
        .then(() => {
          const canvas = document.createElement("canvas");
          const context = assertDefined(canvas.getContext("2d"), "Canvas 2d context missing");
          context.font = `${style.fontSize} ${style.fontFamily}`;
          const valueWidth = context.measureText(valueText).width;
          const fontSize = parseFloat(style.fontSize);
          setAdjustedFontSize(valueWidth > containerWidth ? (containerWidth * fontSize) / valueWidth : fontSize);
        })
        .catch(() => setAdjustedFontSize(parseFloat(style.fontSize)));
    };
    calculateFontSize();
    window.addEventListener("resize", calculateFontSize);
    return () => window.removeEventListener("resize", calculateFontSize);
  }, [value]);

  return (
    <section className={cx("stats", className)}>
      <h2>
        {title}
        {description ? (
          <WithTooltip tip={description} position="top">
            <Icon name="info-circle" />
          </WithTooltip>
        ) : null}
      </h2>
      <div ref={containerRef} style={{ overflow: "hidden", overflowWrap: "initial" }}>
        <span style={adjustedFontSize ? { fontSize: adjustedFontSize } : undefined}>
          {value ? value : valueText === "" ? <Progress width="1.2em" /> : valueText}
        </span>
      </div>
    </section>
  );
};
