import * as React from "react";

import { useRefToLatest } from "./useRefToLatest";

export const useGlobalEventListener = <EventName extends keyof WindowEventMap>(
  eventName: EventName,
  eventHandler: (evt: WindowEventMap[EventName]) => void,
) => {
  // The event handler here is stashed into a reference to allow us to replace the event handler
  // without tearing down & setting up a new event listener when the event handler changes.
  const handlerRef = useRefToLatest(eventHandler);

  React.useEffect(() => {
    const handle = (evt: WindowEventMap[EventName]) => {
      const currentHandler = handlerRef.current;
      currentHandler(evt);
    };

    window.addEventListener(eventName, handle);

    return () => window.removeEventListener(eventName, handle);
  }, [eventName]);
};
