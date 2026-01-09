import { Link } from "@inertiajs/react";
import React from "react";

export const meta = {
  description:
    "In this article: Block customers from purchasing your products Revoke a customer's access to their content",
};

export default function CustomerModeration() {
  return (
    <>
      <div>
        <p>
          <b>In this article:</b>
        </p>
        <ul>
          <li>
            <a href="#Block-customers-from-purchasing-your-products-KNuPa">
              Block customers from purchasing your products
            </a>
          </li>
          <li>
            <a href="#Revoke-a-customers-access-to-their-content-1As4p">Revoke a customer's access to their content</a>
          </li>
        </ul>
        <h3 id="Block-customers-from-purchasing-your-products-KNuPa">Block customers from purchasing your products</h3>
        <p>
          To block problematic customers from purchasing your products, go to the Mass-block emails section in your{" "}
          <a href="https://gumroad.com/settings/advanced">Advanced Settings</a>. Enter one or more email addresses,
          separated by a new line, and click the Update settings button.{" "}
        </p>
        <p>
          <strong>Note:</strong> Adding <em>SampleEmail@gmail.com</em> will also block <em>SampleEmail+1@gmail.com</em>{" "}
          and <em>Sample.Email@gmail.com</em>. This will only block customers from your Gumroad, and they will only know
          about it if they try to purchase from you again in the future.{" "}
        </p>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/63ed4e52e22c9e067d47614a/file-yR0lyCA8yq.png"
            alt=""
          />
        </figure>
        <h3 id="Revoke-a-customers-access-to-their-content-1As4p">Revoke a customer's access to their content</h3>
        <p>
          If you've noticed a customer distributing your content illegally or otherwise violating your terms, you can
          revoke access to their content.{" "}
        </p>
        <p>
          Go to the <a href="https://gumroad.com/customers">Customers dashboard</a>, find the desired customer, and
          click the Revoke access button.{" "}
        </p>
        <p>
          <b>Note: </b>You can't revoke access on fully refunded purchases, membership products, or physical products.
        </p>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/63ed4f9ee22c9e067d47614d/file-GZjfc8xijD.png"
            alt=""
          />
        </figure>
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
            <Link href="/help/article/51-what-is-gumroads-refund-policy">
              <span>Gumroad's refund policy</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/42-content-security">
              <span>Content protection on Gumroad</span>
            </Link>
          </li>
        </ul>
      </div>
    </>
  );
}
