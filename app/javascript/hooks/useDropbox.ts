import { useEffect } from "react";

let loadPromise: Promise<void> | null = null;

export const useDropbox = (apiKey: string | null) => {
  useEffect(() => {
    if (!apiKey || document.getElementById("dropboxjs")) return;

    if (!loadPromise) {
      loadPromise = new Promise<void>((resolve) => {
        const script = document.createElement("script");
        script.id = "dropboxjs";
        script.src = "https://www.dropbox.com/static/api/2/dropins.js";
        script.setAttribute("data-app-key", apiKey);
        script.async = true;
        script.onload = () => resolve();
        // A load that fails leaves this id in the DOM, which is what the guard above matches, so
        // the tag has to come back off or no later mount can request the script again.
        script.onerror = () => {
          script.remove();
          loadPromise = null;
        };
        document.body.appendChild(script);
      });
    }
  }, [apiKey]);
};
