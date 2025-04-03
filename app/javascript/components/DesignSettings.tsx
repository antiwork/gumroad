import * as React from "react";
import { cast } from "ts-safe-cast";

export type DesignSettings = { font: { name: string; url: string } };

const Context = React.createContext<DesignSettings | null>(null);

export const DesignContextProvider = Context.Provider;

export const useFont = (): { name: string; url: string } => {
  const value = React.useContext(Context);
  if (value == null) throw new Error("Cannot read design settings, make sure DesignContextProvider is used");
  return value.font;
};

export const readDesignSettings = (): DesignSettings => {
  const el = document.getElementById("design-settings");
  if (el == null) throw new Error("Cannot read design settings, #design-settings was not rendered into the DOM");
  return cast(JSON.parse(el.dataset.settings ?? ""));
};
