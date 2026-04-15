import { useEffect } from "react";

export const usePersistentExternalScript = (src: string) => {
  useEffect(() => {
    if (document.querySelector(`script[src=${JSON.stringify(src)}]`)) return;

    const script = document.createElement("script");
    script.src = src;
    script.async = true;
    document.body.appendChild(script);

    // Deliberately not cleaning up the script here as our scripts are not designed to be
    // removed and reattached - it causes issues with duplicating elements and event listeners.
  }, [src]);
};
