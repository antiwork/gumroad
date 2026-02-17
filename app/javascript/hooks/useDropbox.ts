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
        document.body.appendChild(script);
      });
    }
  }, [apiKey]);
};
