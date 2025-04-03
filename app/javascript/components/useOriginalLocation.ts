import * as React from "react";

import { assert } from "$app/utils/assert";

const SSRContext = React.createContext<string | null>(null);

export const useOriginalLocation = (): string => {
  const ssrValue = React.useContext(SSRContext);
  const [value] = React.useState(typeof window !== "undefined" ? window.location.href : ssrValue);
  assert(value != null, "Cannot read original location, make sure SSRLocationProvider is used");
  return value;
};

export const SSRLocationProvider = SSRContext.Provider;
