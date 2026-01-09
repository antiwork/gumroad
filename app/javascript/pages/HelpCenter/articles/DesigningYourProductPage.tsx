import { Link } from "@inertiajs/react";
import React from "react";

export const meta = {
  description:
    "In this article: Offering discounts Add custom fields More like this recommendations Creating an Upsell Offering discounts By providing discounts on your produc",
};

export default function DesigningYourProductPage() {
  return (
    <>
      <div>
        <p>
          <strong>In this article:</strong>
        </p>
        <ul>
          <li>
            <a href="#discounts">Offering discounts</a>
          </li>
          <li>
            <a href="#custom-fields">Add custom fields</a>
          </li>
          <li>
            <a href="#More-like-this-recommendations-5J9b1">More like this recommendations</a>
          </li>
          <li>
            <a href="#Creating-an-Upsell-PYDkp">Creating an Upsell</a>
          </li>
        </ul>
        <h3 id="discounts">Offering discounts</h3>
        <p>
          By providing discounts on your product, you can run a sale or offer your customers an attractive price. Read{" "}
          <Link href="/help/article/128-discount-codes">this article</Link> to learn all about discount codes.
        </p>
        <h3 id="custom-fields">Add custom fields</h3>
        <p>
          <a href="https://gumroad.com/checkout/form">Custom fields</a> help you collect additional information from
          your customers, like their Twitter handle, ToS acceptance, or shipping info. You can add three kinds of
          mandatory or optional custom fields:
        </p>
        <ul>
          <li>Textbox</li>
          <li>Checkbox: e.g., “Tick if you are a digital nomad.”</li>
          <li>
            Terms: Enter the URL for your terms that customers must accept before purchasing. This field is always set
            to “Required.”
          </li>
        </ul>
        <p>Each custom field can be applied to all products or only a subset.</p>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/64248bcc4cd1ab01bbe8b082/file-qFRruuIBdB.png"
            alt=""
          />
        </figure>
        <p>
          The custom field info will be accessible in the <a href="https://www.gumroad.com/customers">Sales tab</a> and
          the <Link href="/help/article/74-the-analytics-dashboard#sales-csv">sales CSV</Link>.
        </p>
        <h3 id="More-like-this-recommendations-5J9b1">Recommend related products</h3>
        <p>
          Our <Link href="/help/article/334-more-like-this">Recommend related products</Link> feature allows you to
          recommend other products from your store, products you're an affiliate of, or all of the products found on{" "}
          <a href="https://gumroad.com/discover">Gumroad Discover</a>!
        </p>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/65c3046b0a12eb325db176e7/file-mgZ6SnjBz9.png"
            alt=""
          />
        </figure>
        <h3 id="Creating-an-Upsell-PYDkp">Creating an Upsell</h3>
        <p>
          Upsells allow you to suggest additional products to your customers at checkout. You can either nudge them to
          purchase an upgraded version, replace the product with another one, or add an extra product to the cart.{" "}
        </p>
        <p>
          Read this article to learn more about implementing Upsells in your product checkout process:{" "}
          <Link href="/help/article/331-creating-upsells">Creating an Upsell</Link>
        </p>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/65c304828106ae1c4ab6f390/file-mlXPkvZndM.png"
            alt=""
          />
        </figure>
      </div>
      <div>
        <h3>Related Articles</h3>
        <ul>
          <li>
            <Link href="/help/article/128-discount-codes">
              <span>Discount codes</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/331-creating-upsells">
              <span>Creating an Upsell</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/334-more-like-this">
              <span>Recommend related products</span>
            </Link>
          </li>
        </ul>
      </div>
    </>
  );
}
