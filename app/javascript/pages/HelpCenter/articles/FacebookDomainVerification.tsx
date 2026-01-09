import { Link } from "@inertiajs/react";
import React from "react";

export const meta = {
  description:
    "Starting April 27, 2021, following the release of Apple's iOS 14.5, Facebook began rolling out its new ad measurement protocols. Under this new protocol, one of",
};

export default function FacebookDomainVerification() {
  return (
    <>
      <div>
        <p>
          Starting April 27, 2021, following the release of Apple's iOS 14.5, Facebook began rolling out its new ad
          measurement protocols. Under this new protocol, one of the main actions required from the advertisers is to{" "}
          <a href="https://www.facebook.com/business/help/286768115176155" target="_blank" rel="noreferrer">
            verify their domain
          </a>{" "}
          in{" "}
          <a href="https://business.facebook.com/settings/owned-domains/" target="_blank" rel="noreferrer">
            Facebook Business Manager
          </a>
          .{" "}
        </p>
        <p>
          As Meta mentions{" "}
          <a
            href="https://developers.facebook.com/blog/post/2020/12/16/preparing-partners-ios-14-mobile-web-advertising/"
            target="_blank"
            rel="noreferrer"
          >
            here
          </a>
          , Domain Verification must be done at the effective top level domain plus one (eTLD+1). For example, for{" "}
          <a href="http://www.jasper.com">www.jasper.com</a>, books.jasper.com and jasper.com the eTLD+1 domain is
          jasper.com.
        </p>
        <p>
          You can point your Facebook ad tools directy to your Gumroad profile page at &#123;username&#125;.gumroad.com!
          You are not required to have a custom domain to input a Facebook Meta tag (although{" "}
          <Link href="/help/article/153-setting-up-a-custom-domain">configuring a Custom Domain</Link> will work as
          usual).
        </p>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/624695ac42ba434a7afe227f/file-t2ULtEfIqP.png"
            alt=""
          />
        </figure>
        <h3>Verifying your domain</h3>
        <ol>
          <li>
            Go to your <a href="https://gumroad.com/settings/third_party_analytics">Third-party analytics settings</a>
          </li>
          <li>Toggle on the "Verify domain in third-party services" option</li>
          <li>
            <p>
              Copy the meta tag from your FB Business Manager and paste it in the box right below the toggle option.
              Read FB's documentation about it{" "}
              <a
                href="https://developers.facebook.com/docs/sharing/domain-verification/verifying-your-domain#meta-tags"
                target="_blank"
                rel="noreferrer"
              >
                here
              </a>
              .
            </p>
            <figure>
              <img
                src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/6093b8278996210f18bdab55/file-FxlrzhXlG8.png"
                alt=""
              />
            </figure>
          </li>
          <li>Click "Update settings" on the top-right of the settings page</li>
          <li>
            <p>
              Confirm if the meta tag has been added to your site or not by right-clicking on your home page, select
              "Inspect (Ctrl+Shift+I)", and look for the meta tag in the "Elements" tab as shown in the screenshot
              below.
            </p>
            <figure>
              <img
                src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/6246964bc1e53608cf9ef36b/file-K6CZOAGnMr.png"
                alt=""
              />
            </figure>
            <p>🔍 To zoom in a bit...</p>
            <figure>
              <img
                src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/6093b7a68996210f18bdab54/file-ilmvThnIjq.png"
                alt=""
              />
            </figure>
          </li>
          <li>
            Once you've confirmed that the meta tag has been added to your site, go back to your FB Business Manager and
            click the <strong>Verify</strong> button at the bottom of the Meta Tag Verification tab for the selected
            domain.
          </li>
          <li>
            Leave the meta tag on your domain home page as it may be checked periodically for verification purposes.
          </li>
        </ol>
        <p>
          And we're done! You can now direct ads either to your profile, or individual products, using your custom
          domain!
        </p>
      </div>
      <div>
        <h3>Related Articles</h3>
        <ul>
          <li>
            <Link href="/help/article/67-the-settings-menu">
              <span>Account settings</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/174-third-party-analytics">
              <span>Third-party analytics</span>
            </Link>
          </li>
        </ul>
      </div>
    </>
  );
}
