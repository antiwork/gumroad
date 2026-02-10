import * as React from "react";

const DROPBOX_SCRIPT_URL = "https://www.dropbox.com/static/api/2/dropins.js";

let loadPromise: Promise<void> | null = null;

const loadDropboxScript = (apiKey: string): Promise<void> => {
  if ("Dropbox" in window) {
    return Promise.resolve();
  }

  if (loadPromise) {
    return loadPromise;
  }

  loadPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = DROPBOX_SCRIPT_URL;
    script.id = "dropboxjs";
    script.setAttribute("data-app-key", apiKey);
    script.async = true;
    script.onload = () => {
      resolve();
    };
    script.onerror = () => {
      loadPromise = null;
      reject(new Error("Failed to load Dropbox script"));
    };
    document.head.appendChild(script);
  });

  return loadPromise;
};

export function useDropbox(apiKey: string | null) {
  const [isLoaded, setIsLoaded] = React.useState("Dropbox" in window);

  React.useEffect(() => {
    if (!apiKey || isLoaded) return;

    loadDropboxScript(apiKey)
      .then(() => setIsLoaded(true))
      .catch(() => {});
  }, [apiKey, isLoaded]);

  return { isLoaded };
}
