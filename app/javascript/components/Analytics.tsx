import * as React from "react";

type Event = { name: string };
type LoggerFn = (event: Event) => void;
export type AnalyticsManager = { logEvent: LoggerFn };
type ContextValue = AnalyticsManager;

const Context = React.createContext<ContextValue | null>(null);

export const AnalyticsProvider = Context.Provider;

export const useAnalyticsTrack = (): LoggerFn => {
  const value = React.useContext(Context);
  if (!value) {
    throw new Error("Cannot read from analytics context, make sure AnalyticsProvider is used higher up in the tree");
  }
  return value.logEvent;
};
