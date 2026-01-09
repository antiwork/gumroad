import { Link } from "@inertiajs/react";
import React from "react";

export const meta = {
  description:
    "Every seller has their own unique needs and principles when it comes to issuing refunds, therefore Gumroad allows and encourages its sellers to set their own re",
};

export default function WhatIsGumroadsRefundPolicy() {
  return (
    <>
      <div>
        <p>
          Every seller has their own unique needs and principles when it comes to issuing refunds, therefore Gumroad
          allows and encourages its sellers to{" "}
          <Link href="/help/article/335-custom-refund-policy">set their own refund policies</Link>.
        </p>
        <p>
          That said, Gumroad reserves the right to issue refunds within 90 days of purchase, at its discretion, to
          prevent chargebacks.
        </p>
        <p>
          That said, you can set a "no-refunds" policy, but card networks still allow customers to file{" "}
          <Link href="/help/article/134-how-does-gumroad-handle-chargebacks">chargebacks</Link> at any time.{" "}
          <strong>Too many successful disputes can put your Gumroad account at risk of suspension</strong>, even if your
          policy is clearly stated.{" "}
        </p>
        <p>
          If a customer is threatening a chargeback, we recommend that you offer them a{" "}
          <Link href="/help/article/47-how-to-refund-a-customer#partial">partial refund</Link> using the feature we've
          provided you with.{" "}
        </p>
        <p>
          Learn more about our terms <a href="http://www.gumroad.com/terms">here</a>.
        </p>
        <p>
          And learn more about chargebacks{" "}
          <Link href="/help/article/134-how-does-gumroad-handle-chargebacks" rel="nofollow">
            here
          </Link>
          .
        </p>
      </div>
      <div>
        <h3>Related Articles</h3>
        <ul>
          <li>
            <Link href="/help/article/47-how-to-refund-a-customer">
              <span>Issuing a refund</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/134-how-does-gumroad-handle-chargebacks">
              <span>Chargebacks on Gumroad</span>
            </Link>
          </li>
        </ul>
      </div>
    </>
  );
}
