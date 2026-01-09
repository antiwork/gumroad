import { Link } from "@inertiajs/react";
import React from "react";

export const meta = {
  description:
    "Gumroad is perfect for anyone who makes and sells products. Writers, musicians, filmmakers, SaaS developers, educators (and all in-between) can sell on Gumroad ",
};

export default function IsGumroadForMe() {
  return (
    <>
      <div>
        <p>
          Gumroad is perfect for anyone who makes and sells products. Writers, musicians, filmmakers, SaaS developers,
          educators (and all in-between) can sell on Gumroad to a worldwide audience.{" "}
        </p>
        <h3>Simple setup, powerful sales</h3>
        <p>Once you create an account, you can start selling products on Gumroad quickly.</p>
        <p>
          Just <Link href="/help/article/149-adding-a-product">choose a product type</Link> and start creating:
        </p>
        <figure>
          <img src="help_center/start-creating.png" alt="" />
        </figure>
        <p>
          Once your product is live, send your audience to your Gumroad{" "}
          <Link href="/help/article/124-your-gumroad-profile-page">profile page</Link> or place products{" "}
          <Link href="/help/article/44-build-gumroad-into-your-website">on your website</Link> to start selling.
        </p>
        <h3>Managing customers and sales</h3>
        <p>
          Gumroad allows you to interact with your audience through{" "}
          <Link href="/help/article/169-how-to-send-an-update">emails</Link>,{" "}
          <Link href="/help/article/131-using-workflows-to-send-automated-updates">drip content</Link>,{" "}
          <Link href="/help/article/170-audience">growing followers</Link>, and access to{" "}
          <Link href="/help/article/74-the-analytics-dashboard">sales data</Link>.
        </p>
        <p>
          Not only that, it's easy to <Link href="/help/article/47-how-to-refund-a-customer">issue refunds</Link>,
          update product content, create <Link href="/help/article/128-discount-codes">discount codes</Link>, and{" "}
          <Link href="/help/article/333-affiliates-on-gumroad">add affiliates</Link>. Read more about interacting with
          customers <Link href="/help/article/169-how-to-send-an-update">here</Link>.
        </p>
        <h3>Grow your audience on Discover</h3>
        <p>
          Your Gumroad profile and website aren't the only places where you can make sales. With{" "}
          <Link href="/help/article/79-gumroad-discover">Discover</Link>, your products can appear on our site-wide
          marketplace. Discover works by recommending your products from search and getting you more customers beyond
          your typical audience.
        </p>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/63b6b192d0b6de7e3be2a5ec/file-n0TJUXHpcG.png"
            alt=""
          />
        </figure>
        <h3>A secure purchasing environment </h3>
        <p>
          All credit card information is processed in a PCI-compliant environment certified by an independent auditor.
        </p>
        <p>Every purchase on Gumroad takes place on an encrypted HTTP secure connection.</p>
        <p>Your customers' download links are secure and require email verification if repeatedly used. </p>
        <h3>Fees</h3>
        <p>
          <Link href="/help/article/66-gumroads-fees">Gumroad seller fees</Link> are simple. We only charge a fee when
          you make a sale – no extra monthly charges.{" "}
        </p>
        <h3>Get Paid</h3>
        <p>
          As long as you are able to receive money through PayPal, you can use Gumroad. Residents of some countries are
          able to <Link href="/help/article/13-getting-paid">receive weekly payouts</Link> to their bank accounts.
        </p>
        <p>
          If you are <em>unable</em> to receive money through PayPal because PayPal doesn't work in your country, then
          we have no way to pay you, as we don't have alternate payment methods for people in this situation right now.
        </p>
        <h3>Need help getting from $0 to $1?</h3>
        <p>Check out any of our following free resources:</p>
        <ul>
          <li>
            <a href="https://gumroad.com/university" target="_blank" rel="noreferrer">
              How to use Gumroad
            </a>{" "}
            - learn the ropes of selling online
          </li>
          <li>
            The{" "}
            <a
              href="https://gumroad.gumroad.com/?section=o4PMUt5fxAqrAJY-iUaBCQ%3D%3D"
              target="_blank"
              rel="noreferrer"
            >
              Gumroad Blog
            </a>{" "}
            and Gumroad's High Converting{" "}
            <a href="https://gumroad.com/gumroad" target="_blank" rel="noreferrer">
              Sales Page Course
            </a>
          </li>
          <li>
            Inspiring Stories from the{" "}
            <a href="https://www.youtube.com/@GumroadUniversity/videos" target="_blank" rel="noreferrer">
              Gumroad Podcast
            </a>
          </li>
          <li>
            Our page of{" "}
            <a href="https://gumroad.com/gumroadhelp" target="_blank" rel="noreferrer">
              free product examples
            </a>{" "}
            - see how products work from a customer's perspective
          </li>
          <li>
            <Link href="/help/article/155-things-you-cant-sell-on-gumroad" target="_blank" rel="noreferrer">
              Things that are not allowed on Gumroad
            </Link>
          </li>
        </ul>
      </div>
      <div>
        <h3>Related Articles</h3>
        <ul>
          <li>
            <Link href="/help/article/66-gumroads-fees">
              <span>Gumroad's fees</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/155-things-you-cant-sell-on-gumroad">
              <span>Things not allowed on Gumroad</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/149-adding-a-product">
              <span>Adding a product</span>
            </Link>
          </li>
        </ul>
      </div>
    </>
  );
}
