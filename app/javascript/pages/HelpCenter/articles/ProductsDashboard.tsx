import { Link } from "@inertiajs/react";
import React from "react";

export const meta = {
  description:
    "In this article: Products you have created Archive a product Products you are affiliated to Products you have created The “Products dashboard” allows you to cre",
};

export default function ProductsDashboard() {
  return (
    <>
      <div>
        <p>
          <strong>In this article:</strong>
        </p>
        <ul>
          <li>
            <a href="#all-products">Products you have created</a>
          </li>
          <li>
            <a href="#Archive-a-product-uSFo0">Archive a product</a>
          </li>
          <li>
            <a href="#affiliated">Products you are affiliated to</a>
          </li>
        </ul>
        <h3 id="all-products">Products you have created</h3>
        <p>
          The "Products dashboard" allows you to{" "}
          <Link href="/help/article/149-adding-a-product">create new products</Link>, see product summaries, track{" "}
          <Link href="/help/article/79-gumroad-discover">Discover eligibility</Link>, and view details of affiliated
          products as well.
        </p>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/651e45b3ed8c6d2f1cffdf90/file-4cgKZm6AzN.png"
            alt=""
          />
        </figure>
        <h3 id="Archive-a-product-uSFo0">Archive a product</h3>
        <p>
          You can click the product’s name to edit it, or the three-dot menu on the right to duplicate, archive, or
          permanently delete a product.
        </p>
        <figure style={{ maxWidth: "100%" }}>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/649d5af1cfd7fe604a7fe38a/file-uuXfjiuxNZ.png"
            alt=""
          />
          <figcaption> The three-dot menu </figcaption>
        </figure>
        <p>
          Archiving helps you hide your product from most of Gumroad without deleting it completely, thus preventing
          adverse consequences like losing ongoing sales.{" "}
        </p>
        <p>
          Archived products will not show while creating new discounts, upsells, or affiliates, and will be hidden from
          your profile. You will be able to see past sales or edit existing checkout options and affiliates for these
          products though.
        </p>
        <p>
          If needed, you can unarchive them from the "Archived" tab which is visible only if you have an archived
          product.
        </p>
        <h3 id="affiliated">Products you are affiliated to</h3>
        <p>
          The <a href="https://gumroad.com/products/affiliated">Affiliated tab</a> is currently the closest thing to a
          "Dashboard for Affiliates" on Gumroad.{" "}
        </p>
        <figure style={{ maxWidth: "100%" }}>
          <img src="help_center/affiliate-tab.png" alt="" />
          <figcaption> The Affiliated dashboard </figcaption>
        </figure>
        <p>
          Archiving helps you hide your product from most of Gumroad without deleting it completely, thus preventing
          adverse consequences like losing ongoing sales.{" "}
        </p>
        <p>
          Archived products will not show while creating new discounts, upsells, or affiliates, and will be hidden from
          your profile. You will be able to see past sales or edit existing checkout options and affiliates for these
          products though.
        </p>
        <p>
          If needed, you can unarchive them from the “Archived” tab which is visible only if you have an archived
          product.
        </p>
        <h3 id="affiliated">Products you are affiliated to</h3>
        <p>
          The <a href="https://gumroad.com/products/affiliated">Affiliated tab</a> is currently the closest thing to a
          "Dashboard for Affiliates" on Gumroad.{" "}
        </p>
        <figure style={{ maxWidth: "100%" }} className="">
          <img src="help_center/affiliate-tab.png" alt="" />
          <figcaption> The Affiliated dashboard </figcaption>
        </figure>
        <p>Once a Gumroad creator adds you as an affiliate, you should see the affiliated product here. </p>
        <p>
          Please note that you cannot remove yourself as an affiliate for any product; you will have to contact the
          product's creator for that.
        </p>
      </div>
      <div>
        <h3>Related Articles</h3>
        <ul>
          <li>
            <Link href="/help/article/149-adding-a-product">
              <span>Adding a product</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/82-membership-products">
              <span>Selling memberships</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/249-affiliate-faq">
              <span>Becoming an affiliate on Gumroad</span>
            </Link>
          </li>
        </ul>
      </div>
    </>
  );
}
