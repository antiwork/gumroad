import { Link } from "@inertiajs/react";
import React from "react";

export const meta = {
  description:
    "You can change the URL of your product by editing the gray text under the product description on the edit page. For example, you can change: annagreen.gumroad.c",
};

export default function CustomProductUrls() {
  return (
    <>
      <div>
        <p>
          You can change the URL of your product by editing the gray text under the product description on the edit
          page. For example, you can change:
        </p>
        <p></p>
        <p>
          annagreen.gumroad.com/l/<b>QaSmj </b>
        </p>
        <p>to </p>
        <p>
          annagreen.gumroad.com/l/<b>poetryclub</b>
        </p>
        <figure>
          <img
            src="https://lh6.googleusercontent.com/zljKufCmS0GdSXxRzz6mGOQOZoOhigO6TMfJ9CedSNEbuT8dWdR3oPhfVQrMdQFsW1y9APs2oo0efK32s1t1a2f889yfpIjCwKRV5KuvSoNHKetRI0km11Fwu6NbEvE7kp1YOfXbF2HjMLEU5ftz63M"
            width={503}
            height={448}
            alt=""
          />
        </figure>
        <br />
        <p>
          You can update this link at any time, but your previous custom URL will <span>not</span> redirect to the new
          custom URL.{" "}
        </p>
        <p>
          Your default Gumroad product link (annagreen.gumroad.com/l/QaSmj in this case) will continue to work as well.
        </p>
      </div>
      <div>
        <h3>Related Articles</h3>
        <ul>
          <li>
            <Link href="/help/article/153-setting-up-a-custom-domain">
              <span>Setting up a custom domain</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/149-adding-a-product">
              <span>Adding a product</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/101-designing-your-product-page">
              <span>Checkout customization</span>
            </Link>
          </li>
        </ul>
      </div>
    </>
  );
}
