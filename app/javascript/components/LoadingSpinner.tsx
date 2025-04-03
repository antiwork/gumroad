import * as React from "react";

import { Progress } from "$app/components/Progress";

type Props = {
  // It's only grey for now, but we can add a white variation when needed.
  color?: "grey";
  width?: string;
};
export const LoadingSpinner = ({ color = "grey", width = "1em" }: Props) => (
  <>
    <Progress width={width} />
    <div className={`loading-spinner-component loading-spinner-component--${color} legacy-only`} />
  </>
);
