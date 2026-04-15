declare module "$vendor/facebook_pixel" {
  const loadFacebookPixelScript: () => void;
  export default loadFacebookPixelScript;
}

declare module "$vendor/google_analytics_4" {
  const loadGoogleAnalyticsScript: () => void;
  export default loadGoogleAnalyticsScript;
}

declare module "$vendor/tiktok_pixel" {
  const loadTikTokPixelScript: () => void;
  export default loadTikTokPixelScript;
}

declare const ttq: {
  load: (pixelId: string) => void;
  page: () => void;
  track: (event: string, params?: Record<string, unknown>) => void;
  instance: (pixelId: string) => {
    track: (event: string, params?: Record<string, unknown>) => void;
    page: () => void;
  };
};
