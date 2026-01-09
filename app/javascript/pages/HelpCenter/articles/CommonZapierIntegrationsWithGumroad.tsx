import { Link } from "@inertiajs/react";
import React from "react";

export const meta = {
  description:
    "Zapier is a tool used by many Gumroad creators to help integrate their Gumroad stores into other applications, or automate their post-sale tasks (like adding cu",
};

export default function CommonZapierIntegrationsWithGumroad() {
  return (
    <>
      <div>
        <figure>
          <img
            src="https://d33v4339jhl8k0.cloudfront.net/docs/assets/5c4657ad2c7d3a66e32d763f/images/63231ce9f498d67325e89f21/file-JmrfXFwg0O.png"
            alt=""
          />
        </figure>
        <p>
          <a href="http://www.zapier.com" target="_blank" rel="noreferrer">
            Zapier
          </a>{" "}
          is a tool used by many Gumroad creators to help integrate their Gumroad stores into other applications, or
          automate their post-sale tasks (like adding customers to a mailing list, or sending out dripped content). To
          use Zapier with Gumroad, you have to first create a Zapier account, then give it access to your Gumroad store
          (to scrape sales data for you).{" "}
        </p>
        <p>
          {" "}
          Zapier's pricing plans are based on how many of these automated tasks you can be found{" "}
          <a href="https://zapier.com/pricing" target="_blank" rel="noreferrer">
            here
          </a>
          .
        </p>
        <p>
          {" "}
          Please be aware that it often takes Zapier 24-48 hours to update their dashboard when you make changes on your
          products. So, if you add custom fields to your product purchase form, Zapier won't "pick up" that those
          changes have happened for a day or two.{" "}
        </p>
        <p> Some of the common integrations available with Gumroad via Zapier are:</p>
        <ul>
          <li>Mailchimp</li>
          <li>Google Sheets</li>
          <li>AWeber</li>
          <li>ConvertKit</li>
          <li>Discord</li>
          <li>Slack</li>
          <li>Campaign Monitor</li>
          <li>
            <a href="https://zapier.com/apps/gumroad/integrations" target="_blank" rel="noreferrer">
              And MANY more!
            </a>
          </li>
        </ul>
        <p>
          {" "}
          Zapier will take you through the steps of completing each integration on how to create some extremely useful
          "Zaps" that allow you to spend more of your time focused on creating stuff (or, you know, doing the laundry or
          something).
        </p>
      </div>
      <div>
        <h3>Related Articles</h3>
        <ul>
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
