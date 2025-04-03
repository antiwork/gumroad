const OAUTH_REDIRECT_CHECK_INTERVAL = 500;

export const startOauthRedirectChecker = ({
  oauthPopup,
  onSuccess,
  onError,
  onPopupClose,
}: {
  oauthPopup: Window | null;
  onSuccess: (code: string) => Promise<void>;
  onError: () => void;
  onPopupClose: () => void;
}) => {
  const oauthRedirectChecker = setInterval(() => {
    const stopOauthRedirectChecker = () => clearInterval(oauthRedirectChecker);

    if (!oauthPopup || oauthPopup.closed) {
      stopOauthRedirectChecker();
      onPopupClose();
      return;
    }

    try {
      const currentUrl = oauthPopup.location.href;
      if (!currentUrl) return;

      const searchParams = new URL(currentUrl).searchParams;
      const code = searchParams.get("code");
      const error = searchParams.get("error");
      if (code || error) {
        oauthPopup.close();
        if (code) {
          void onSuccess(code).then(() => {
            stopOauthRedirectChecker();
          });
        } else {
          onError();
          stopOauthRedirectChecker();
        }
      } else if (currentUrl.includes("oauth_redirect")) {
        onError();
        stopOauthRedirectChecker();
      }
    } catch {}
  }, OAUTH_REDIRECT_CHECK_INTERVAL);
};
