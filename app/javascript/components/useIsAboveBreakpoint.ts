import * as React from "react";

import { getCssVariable } from "$app/utils/styles";

import { useUserAgentInfo } from "$app/components/UserAgent";
import { useWindowDimensions } from "$app/components/useWindowDimensions";

type Breakpoint = "sm" | "lg";

// Use to find out if the page is currently being displayed above the given breakpoint.
// During SSR it returns false if the user-agent is mobile, true otherwise.
export const useIsAboveBreakpoint = (breakpoint: Breakpoint) => {
  const dimensions = useWindowDimensions();
  const userAgentInfo = useUserAgentInfo();
  return React.useMemo(() => {
    if (dimensions === null) return !userAgentInfo.isMobile;
    const breakpointWidth = parseInt(getCssVariable(`breakpoint-${breakpoint}`), 10);
    return dimensions.width >= breakpointWidth;
  }, [dimensions]);
};
