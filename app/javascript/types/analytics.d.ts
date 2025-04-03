declare module "$vendor/facebook_pixel" {
  const loadFacebookPixelScript: () => void;
  export default loadFacebookPixelScript;
}

declare module "$vendor/google_analytics_4" {
  const loadGoogleAnalyticsScript: () => void;
  export default loadGoogleAnalyticsScript;
}
