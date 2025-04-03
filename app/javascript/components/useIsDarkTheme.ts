import * as React from "react";

export const useIsDarkTheme = () => {
  const [isDarkTheme, setIsDarkTheme] = React.useState<boolean | null>(null);
  React.useEffect(() => {
    const match = matchMedia("(prefers-color-scheme: dark)");
    setIsDarkTheme(match.matches);
    const listener = (e: MediaQueryListEvent) => setIsDarkTheme(e.matches);
    match.addEventListener("change", listener);
    return () => match.removeEventListener("change", listener);
  }, []);
  return isDarkTheme;
};
