import * as React from "react";

const DROPBOX_DROPINS_URL = "https://www.dropbox.com/static/api/2/dropins.js";

let loadPromise: Promise<void> | null = null;

const loadDropboxScript = (appKey: string): Promise<void> => {
  // Already loaded
  if (typeof window !== "undefined" && "Dropbox" in window) {
    return Promise.resolve();
  }

  // Loading in progress
  if (loadPromise) {
    return loadPromise;
  }

  loadPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.id = "dropboxjs";
    script.src = DROPBOX_DROPINS_URL;
    script.async = true;
    script.setAttribute("data-app-key", appKey);
    script.onload = () => {
      resolve();
    };
    script.onerror = () => {
      loadPromise = null;
      reject(new Error("Failed to load Dropbox Drop-ins script"));
    };
    document.head.appendChild(script);
  });

  return loadPromise;
};

export function useDropboxDropins(appKey: string | null | undefined) {
  const [isLoaded, setIsLoaded] = React.useState(typeof window !== "undefined" && "Dropbox" in window);
  const [isLoading, setIsLoading] = React.useState(false);
  const [error, setError] = React.useState<Error | null>(null);

  React.useEffect(() => {
    if (!appKey || isLoaded) return;

    setIsLoading(true);
    loadDropboxScript(appKey)
      .then(() => {
        setIsLoaded(true);
        setIsLoading(false);
      })
      .catch((err: Error) => {
        setError(err);
        setIsLoading(false);
      });
  }, [appKey, isLoaded]);

  const choose = React.useCallback(
    (options: Parameters<typeof Dropbox.choose>[0]) => {
      if (!isLoaded) {
        console.error("Dropbox Drop-ins not loaded");
        return;
      }
      window.Dropbox.choose(options);
    },
    [isLoaded],
  );

  const save = React.useCallback(
    (options: Parameters<typeof Dropbox.save>[0]) => {
      if (!isLoaded) {
        console.error("Dropbox Drop-ins not loaded");
        return;
      }
      window.Dropbox.save(options);
    },
    [isLoaded],
  );

  return { isLoaded, isLoading, error, choose, save };
}
