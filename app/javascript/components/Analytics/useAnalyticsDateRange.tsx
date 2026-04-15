import { router } from "@inertiajs/react";
import { lightFormat, parseISO, subMonths } from "date-fns";
import * as React from "react";

import { useOriginalLocation } from "$app/components/useOriginalLocation";

export const useAnalyticsDateRange = () => {
  const location = useOriginalLocation();
  const url = new URL(location);

  const tryParseDateParam = (paramName: string) => {
    const param = url.searchParams.get(paramName);
    if (!param) return null;
    const parsed = parseISO(param);
    return isNaN(parsed.getTime()) ? null : parsed;
  };

  const [from, setFrom] = React.useState(() => tryParseDateParam("from") ?? subMonths(new Date(), 1));
  const [to, setTo] = React.useState(() => {
    const value = tryParseDateParam("to") ?? new Date();
    return value < from ? from : value;
  });

  React.useEffect(() => {
    const url = new URL(window.location.href);
    url.searchParams.set("from", lightFormat(from, "yyyy-MM-dd"));
    url.searchParams.set("to", lightFormat(to, "yyyy-MM-dd"));
    router.replace({ url: url.toString(), preserveState: true, preserveScroll: true });
  }, [from.getTime(), to.getTime()]);

  return { from, to, setFrom, setTo };
};
