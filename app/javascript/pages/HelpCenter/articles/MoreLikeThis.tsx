import React from "react";

export const meta = {
  description:
    "Providing recommendations to your customers can bring awareness to other products offered in your store and motivate them to try out different items.  To update",
};

export default function MoreLikeThis() {
  return (
    <>
      <div>
        <p>
          Providing recommendations to your customers can bring awareness to other products offered in your store and
          motivate them to try out different items.{" "}
        </p>
        <br />
        <p>To update this setting:</p>
        <ol>
          <li>
            Navigate to the <a href="https://gumroad.com/checkout/form">Checkout form</a> tab on the Checkout dashboard,
            and select the “Recommend my products” radio button.{" "}
          </li>
          <li>Click “Save changes”</li>
        </ol>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/64faaab126847651a7f546df/file-kOBfkPvf56.png"
            alt=""
          />
        </figure>
        <p>
          Now a grid of your products will be displayed on the buyer's checkout page. This won’t include products the
          buyer has already purchased or products currently in the buyer’s cart.{" "}
        </p>
        <p>
          Recommendations are based on purchases made by other buyers, so if the product has no purchasers in common
          with your other products, you won’t get any recommendations.
        </p>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/64df7fc8e3ee466b38a4daea/file-rxt3uxfu5A.png"
            alt=""
          />
        </figure>
        <p>
          Once a customer clicks on a recommended product, they will be directed to the product page where they can
          easily add it to their cart.
        </p>
        <h3>Recommending other products</h3>
        <p>You have the option of recommending other creators' products on your checkout page as well.</p>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/64faaaf9065ccf64a20440a8/file-SX1LaBg7Ct.png"
            alt=""
          />
        </figure>
        <p>
          <b>Recommend my products and products I'm an affiliate of </b>allows you to recommend products that you’re a
          direct affiliate of and earn your affiliate commission if a customer checks out with it.
        </p>
        <p>
          <b>Recommend all products and earn a commission with Gumroad Affiliates</b> allows you to recommend products
          that you’re a direct affiliate of <span>and</span> products eligible for{" "}
          <a href="/help/article/333-affiliates-on-gumroad#Gumroad-Affiliates-sIp2H">Gumroad Affiliates</a>. Directly
          affiliated products yield your full affiliate commission, while Gumroad Affiliate products earn you a 10%
          commission.
        </p>
      </div>
      <div>
        <h3>Related Articles</h3>
        <ul>
          <li>
            <a href="/help/article/149-adding-a-product">
              <span>Adding a product</span>
            </a>
          </li>
          <li>
            <a href="/help/article/128-discount-codes">
              <span>Discount codes</span>
            </a>
          </li>
          <li>
            <a href="/help/article/331-creating-upsells">
              <span>Creating an Upsell</span>
            </a>
          </li>
        </ul>
      </div>
    </>
  );
}
