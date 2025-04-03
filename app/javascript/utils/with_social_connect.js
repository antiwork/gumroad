import "$vendor/jquery.oauthpopup";
export default WithSocialConnect;

function WithSocialConnect() {
  this.defaultAttrs({ twitterPath: "/users/auth/twitter?state=async_link_twitter_account" });

  // returns true or false based on whether perm is verified to be enabled
  this.getPermissionStatusFromFBResponse = function (response, permission) {
    if (typeof response.error === "undefined") {
      if (typeof response.data !== "undefined" && typeof response.data[0] !== "undefined") {
        return !!response.data[0][permission];
      }
    }
  };

  this.persistFacebookAccessToken = function (token) {
    $.ajax({
      type: "POST",
      dataType: "JSON",
      url: Routes.ajax_facebook_access_token_path(),
      data: { accessToken: token },
    });
    return false;
  };

  // Make sure this works when Megaphone is re-enabled as we've added a no-tracking feature.
  // See https://github.com/gumroad/web/pull/16941/files#r556685303
  /* Connects current user to Facebook and persists user info
   *
   * takes the following options
   *
   * success: success callback
   * failure: failure callback
   * facebookOptions: (optional) options to pass to FB.login
   * verifyPermissions: (optional) array of permissions to check are enabled
   *  after connecting
   *
   */
  this.connectFacebook = function (options) {
    const that = this;
    FB.login((response) => {
      let token,
        verified = true;
      if (response && response.authResponse) {
        token = response.authResponse.accessToken;
        FB.api("me/permissions", (response) => {
          if (response && typeof response.error === "undefined") {
            $.each(options.verifyPermissions || [], (i, permission) => {
              verified &&= that.getPermissionStatusFromFBResponse(response, permission);
            });
            if (verified) {
              that.persistFacebookAccessToken(token);
              options.success();
            } else {
              options.failure();
            }
          } else {
            options.failure();
          }
        });
      } else {
        options.failure();
      }
    }, options.facebookOptions || {});
  };

  this.connectTwitter = function (options) {
    const popupOptions = {
      path: this.attr.twitterPath,
      callback() {
        $.ajax({ type: "GET", url: Routes.check_twitter_link_path(), dataType: "JSON" }).done((response) => {
          if (response.success) {
            options.success();
          } else {
            options.failure();
          }
        });
      },
    };

    $.oauthpopup(popupOptions);
  };
}
