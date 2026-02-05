import * as React from "react";

const DROPBOX_SCRIPT_URL = "https://www.dropbox.com/static/api/2/dropins.js";

let loadPromise: Promise<void> | null = null;

interface DropboxFile {
  id: string;
  link: string;
  bytes: number;
  name: string;
}

const getDropboxApiKey = (): string => {
  if (typeof process !== "undefined" && process.env.DROPBOX_PICKER_API_KEY) {
    return String(process.env.DROPBOX_PICKER_API_KEY);
  }

  if (typeof document !== "undefined") {
    const existingScript = document.querySelector("script[data-app-key][src*='dropbox.com/static/api/2/dropins.js']");
    const existingKey = existingScript?.getAttribute("data-app-key");
    if (existingKey) return existingKey;
  }

  return "";
};

const loadDropboxScript = (): Promise<void> => {
  // Use typeof window guard for SSR safety and to satisfy no-unnecessary-condition
  if (typeof window === "undefined") return Promise.resolve();
  if (window.Dropbox) return Promise.resolve();

  if (loadPromise) {
    return loadPromise;
  }

  const dropboxApiKey = getDropboxApiKey();

  loadPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = DROPBOX_SCRIPT_URL;
    script.async = true;
    script.setAttribute("data-app-key", dropboxApiKey);
    script.onload = () => resolve();
    script.onerror = () => {
      loadPromise = null;
      reject(new Error("Failed to load Dropbox script"));
    };
    document.head.appendChild(script);
  });

  return loadPromise;
};

export function useDropbox() {
  const [isLoaded, setIsLoaded] = React.useState(false);
  const [error, setError] = React.useState<Error | null>(null);

  React.useEffect(() => {
    loadDropboxScript()
      .then(() => setIsLoaded(true))
      .catch((err: unknown) => setError(err instanceof Error ? err : new Error(String(err))));
  }, []);

  const choose = (options: {
    linkType: "direct";
    multiselect: boolean;
    success: (files: DropboxFile[]) => void;
    cancel?: () => void;
    extensions?: string[][];
  }) => {
    if (typeof window === "undefined" || !window.Dropbox) {
      options.cancel?.();
      return;
    }
    window.Dropbox.choose(options);
  };

  return { isLoaded, error, choose };
}
