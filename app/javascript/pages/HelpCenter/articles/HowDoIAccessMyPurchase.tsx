import { Link } from "@inertiajs/react";
import React from "react";

export const meta = {
  description:
    "In this article, we explain how to access your digital purchase from Gumroad. If you are trying to find out when your physical purchase will arrive, you will ne",
};

export default function HowDoIAccessMyPurchase() {
  return (
    <>
      <div>
        <p>
          In this article, we explain how to access your digital purchase from Gumroad. If you are trying to find out
          when your physical purchase will arrive, you will need to{" "}
          <Link href="/help/article/215-when-will-my-purchase-be-shipped">contact your product's creator</Link>.
        </p>
        <h3>Accessing from your receipt</h3>
        <p>
          To access a digital product, pull up your email receipt. Click the "View content” button to go to the
          product’s download page.
        </p>
        <p>
          If you have not received an email receipt, please check your spam folder. If you still can't locate it, please{" "}
          <Link href="/help/article/196-contact-gumroad">contact us</Link>.
        </p>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/65b0e4b487e88924b5fa2015/file-5q7QumzVdW.png"
            alt=""
          />
        </figure>
        <p>
          Before being redirected to the download page, you might be asked for your email address. Simply enter the
          email you used at checkout, and you should be able to access the download page.{" "}
        </p>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/64ecbd55e82ed15ede51f41a/file-m4Hln0rbnh.png"
            alt=""
          />
        </figure>
        <h3>Accessing from the Gumroad Library</h3>
        <p>
          Alternatively, you can <a href="https://gumroad.com/signup">create a Gumroad account</a> using the email
          address you previously bought your product(s) with. With a Gumroad account, you will be able to access your
          purchases at any time from your <a href="http://gumroad.com/library">Library</a>.
        </p>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/64b7ac54c2f5ed048130c832/file-Vmap8FQgO4.png"
            alt=""
          />
        </figure>
      </div>
      <div>
        <h3>Related Articles</h3>
        <ul>
          <li>
            <Link href="/help/article/193-my-purchase-isnt-downloading">
              <span>My purchase isn't downloading</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/212-i-never-received-a-receipt">
              <span>I never received a receipt</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/215-when-will-my-purchase-be-shipped">
              <span>When will my purchase be shipped?</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/211-im-not-receiving-updates">
              <span>I'm not receiving updates</span>
            </Link>
          </li>
        </ul>
      </div>
    </>
  );
}
