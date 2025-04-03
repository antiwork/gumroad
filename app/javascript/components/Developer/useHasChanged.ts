import * as React from "react";

export const useHasChanged = (deps: readonly unknown[]) => {
  const [hasChanged, setHasChanged] = React.useState(true);

  React.useEffect(() => setHasChanged(true), deps);
  React.useEffect(() => setHasChanged(false), [hasChanged]);

  return hasChanged;
};
