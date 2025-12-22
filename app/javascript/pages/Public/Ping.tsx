import { Link } from "@inertiajs/react";
import React from "react";

import { Layout } from "$app/components/Developer/Layout";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

type PingParameter = {
  name: string;
  description: string | React.ReactNode;
};

const Code = ({ children }: { children: React.ReactNode }) => (
  <code className="rounded border border-border bg-active-bg px-2 py-1 text-xs align-middle">{children}</code>
);

const PING_PARAMETERS: PingParameter[] = [
  { name: "sale_id", description: "The id of the sale" },
  { name: "sale_timestamp", description: "The timestamp of the sale" },
  { name: "order_number", description: "Numeric version of sale_id" },
  { name: "seller_id", description: "-" },
  { name: "product_id", description: "-" },
  { name: "product_permalink", description: "-" },
  { name: "short_product_id", description: "Unique identifier for the product" },
  { name: "product_name", description: "-" },
  { name: "email", description: "The email of the buyer" },
  { name: "url_params", description: <Code>{"{'source_url' : 'https%3A%2F%2Fgumroad.com%2Fwidgets', 'campaignid' : 'c123', 'userid' : '456', 'version' : '1.4.5'}"}</Code> },
  { name: "full_name", description: "If present, the name of the buyer" },
  { name: "purchaser_id", description: "The id of the purchaser's Gumroad account, if the purchaser has one" },
  { name: "subscription_id", description: "The id of the subscription, if the purchase is part of a subscription" },
  { name: "ip_country", description: "If present, the country of the buyer's IP address" },
  { name: "price", description: "The price paid, in USD cents" },
  { name: "recurrence", description: "If present, the recurrence of the payment option chosen by the buyer such as 'monthly', 'yearly', etc" },
  { name: "variants", description: <>If present, a dictionary <Code>{"{'size' : 'large', 'color' : 'red'}"}</Code></> },
  { name: "offer_code", description: "If present" },
  { name: "test", description: "If you are buying your own product, for testing purposes" },
  { name: "custom_fields", description: <>If present, a dictionary <Code>{"{'name' : 'john smith', 'spouse name' : 'jane smith'}"}</Code></> },
  { name: "shipping_information", description: "If present, a dictionary" },
  { name: "is_recurring_charge", description: "If relevant, a boolean" },
  { name: "is_preorder_authorization", description: "If relevant, a boolean" },
  { name: "license_key", description: "If licenses are enabled for the product" },
  { name: "quantity", description: "-" },
  { name: "shipping_rate", description: "The shipping paid, in USD cents, if the product is a physical product" },
  { name: "affiliate", description: "If present, the affiliate's email address" },
  { name: "affiliate_credit_amount_cents", description: "If present, the amount paid to the affiliate in USD cents" },
  { name: "is_gift_receiver_purchase", description: "true if a gift, false otherwise" },
  { name: "gifter_email", description: "Email address of gifter" },
  { name: "gift_price", description: "The price paid by the gifter, in USD cents" },
  { name: "refunded", description: "true if this sale has been refunded, false otherwise" },
  { name: "discover_fee_charged", description: "true if this sale was subject to Gumroad Discover fees, false otherwise" },
  { name: "can_contact", description: "-" },
  { name: "referrer", description: "-" },
  { name: "gumroad_fee", description: "Gumroad's fee, in USD cents" },
  { name: "card", description: "Payment instrument details" },
];

const PublicPing = () => (
  <Layout currentPage="ping">
    <main className="p-4 md:p-8">
      <div className="mx-auto max-w-5xl">
        <article className="flex flex-col gap-8">
          <header>
            <h1 className="text-3xl font-bold">Gumroad Ping</h1>
          </header>
          <div className="flex flex-col gap-4">
            <p>Gumroad Ping is a simple alert that notifies you in real time whenever one of your products is purchased.</p>

            <div>
              <p>For example, you can use Gumroad Ping to:</p>
              <ul className="ml-6 mt-2 list-disc space-y-1">
                <li>Thank the purchaser publicly on your website.</li>
                <li>Generate QR codes.</li>
                <li>Create an account for them on your own platform.</li>
              </ul>
            </div>

            <p>
              The ping comes in the form of an HTTP POST request to the URL that you specify in your{" "}
              <Link href={Routes.settings_advanced_path()}>account settings</Link>.
              The payload is x-www-form-urlencoded. If your endpoint does not return a 200 HTTP status code, the POST is retried once an hour for up to 3 hours.
            </p>

            <p>In each request, Gumroad sends the parameters in the table below.</p>

            <p>
              You can also use our API and{" "}
              <Link href={`${Routes.api_path()}#resource-subscriptions`}>subscribe</Link>
              {" "}to be notified of future sales.
            </p>

            <p>You can pass unique URL parameters by adding them to any Gumroad product URL. If passed, they will show up in the url_params dictionary as seen below.</p>

            <p>For security reasons we highly recommend that you use an HTTPS endpoint as your URL.</p>
          </div>

          <div className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Parameter</TableHead>
                  <TableHead>Description</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {PING_PARAMETERS.map((param) => (
                  <TableRow key={param.name}>
                    <TableCell className="font-mono text-sm font-medium">
                      {param.name}
                    </TableCell>
                    <TableCell>
                      {param.description}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </article>
      </div>
    </main>
  </Layout>
);

export default PublicPing;
