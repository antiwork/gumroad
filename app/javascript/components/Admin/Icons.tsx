import * as React from "react";

import { Icon } from "$app/components/Icons";

export const YesIcon = () => (
  <Icon name="solid-check-circle" aria-label="Yes" style={{ color: "rgb(var(--success))" }} />
);
export const NoIcon = () => <Icon name="x-circle-fill" aria-label="No" style={{ color: "rgb(var(--danger))" }} />;
