import { Link } from "@inertiajs/react";
import React from "react";

import { Layout } from "$app/components/Developer/Layout";
import CodeSnippet from "$app/components/ui/CodeSnippet";
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
  { name: "currency", description: "The currency the product is listed in. Price and the other amount fields are always USD cents, whatever this value is" },
  { name: "recurrence", description: "If present, the recurrence of the payment option chosen by the buyer such as 'monthly', 'yearly', etc" },
  { name: "variants", description: <>If present, a dictionary <Code>{"{'size' : 'large', 'color' : 'red'}"}</Code></> },
  { name: "offer_code", description: "If present" },
  { name: "test", description: "true if you bought your own product, or for a test ping or test event" },
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
  { name: "resource_name", description: <>What the ping is about. <Code>sale</Code> for a purchase, <Code>refund</Code> when the same purchase is later refunded</> },
  { name: "retry_count", description: "Only present on a retried delivery: 1, 2 or 3" },
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
              The payload is x-www-form-urlencoded. Return any 2xx status to acknowledge it; nothing in your response body is read.
            </p>

            <div>
              <p>Delivery works like this, and it is worth building against rather than inferring:</p>
              <ul className="ml-6 mt-2 list-disc space-y-1">
                <li>Delivery is at least once. The same ping can arrive more than once, so deduplicate.</li>
                <li>Ordering is not guaranteed. A refund ping can reach you before the sale ping it refers to.</li>
                <li>
                  Deduplicate on <Code>sale_id</Code> together with <Code>resource_name</Code>, not on <Code>sale_id</Code> alone.
                  A refund carries the same <Code>sale_id</Code> as the sale it reverses.
                </li>
                <li>
                  A failed delivery is retried after 1 minute, 3 minutes, 10 minutes and 1 hour, then stops. Only 499, 500, 502,
                  503 and 504 are retried. Any other non-2xx response is not, and neither is a connection error or a timeout.
                </li>
                <li>Your endpoint has 5 seconds to respond. Acknowledge first and do your work afterwards.</li>
              </ul>
            </div>

            <p>
              Deliveries can be dropped once the retries run out, so treat a ping as a trigger rather than as data: take{" "}
              <Code>sale_id</Code>, read the sale back through the API, and reconcile periodically against your own
              records. A signature tells you the request came from us; it does not make the payload the source of truth.
            </p>

            <div id="verifying-pings">
              <h2 className="text-xl font-bold">Verifying a ping</h2>
              <p className="mt-2">
                Signing is off by default. Turn it on in your{" "}
                <Link href={Routes.settings_advanced_path()}>account settings</Link> and we sign every ping we send to
                your endpoint, with a secret you can rotate there whenever you like. Until you do, the endpoint URL is
                the only credential on a request, and it leaks through access logs, proxies and browser history.
              </p>
              <p className="mt-2">
                This covers the pings we send to your Ping URL, including the test ping. Notifications for API resource
                subscriptions go to your application's own URL, and are not signed with this secret.
              </p>
              <p className="mt-2">A signed ping carries one extra header:</p>
              <CodeSnippet caption="Signature header">X-Gumroad-Signature: t=1751472000,v1=9d0b9b0a...</CodeSnippet>
              <p className="mt-2">
                <Code>t</Code> is the Unix time, in seconds, at the moment we sent the request. <Code>v1</Code> is the
                hex HMAC-SHA256 of <Code>t</Code>, a period, and the request body exactly as it arrived. Sign the raw
                bytes, not a copy you re-encoded from parsed parameters: form-encoding key order and JSON whitespace both
                change the bytes, and with them the signature. In the examples below, <Code>t</Code> and{" "}
                <Code>v1</Code> are the strings from the header and the raw body is the unparsed bytes.
              </p>
              <CodeSnippet caption="Node">{`const MAX_SKEW_SECONDS = 300;
if (!/^\\d+$/.test(t) || Math.abs(Date.now() / 1000 - Number(t)) > MAX_SKEW_SECONDS)
  return res.status(400).send("stale");
const expected = Buffer.from(crypto.createHmac("sha256", secret)
  .update(t + ".").update(rawBody).digest("hex"));
const received = Buffer.from(v1);
// timingSafeEqual throws unless both buffers have the same byte length,
// and a forged v1 can have any.
if (expected.length !== received.length || !crypto.timingSafeEqual(expected, received))
  return res.status(400).send("bad signature");`}</CodeSnippet>
              <CodeSnippet caption="Python">{`MAX_SKEW_SECONDS = 300
if not (t.isascii() and t.isdigit()) or abs(time.time() - int(t)) > MAX_SKEW_SECONDS:
    abort(400, "stale")
expected = hmac.new(secret.encode(), f"{t}.".encode() + raw_body, hashlib.sha256).hexdigest()
# compare_digest raises on non-ASCII str, so compare bytes.
if not hmac.compare_digest(expected.encode(), v1.encode()):
    abort(400, "bad signature")`}</CodeSnippet>
              <ul className="ml-6 mt-2 list-disc space-y-1">
                <li>
                  Reject a timestamp more than 5 minutes from your own clock. That is what makes a captured request
                  useless later, and a retry always carries a fresh one.
                </li>
                <li>
                  Compare the two values without short-circuiting. <Code>timingSafeEqual</Code> (Node) and{" "}
                  <Code>compare_digest</Code> (Python) are the ones to reach for.
                </li>
                <li>
                  A retried ping re-signs with a new timestamp, so its signature differs from the attempt before it while
                  the payload stays the same. Deduplicate on <Code>sale_id</Code> and <Code>resource_name</Code>, never on
                  the signature.
                </li>
                <li>
                  Rotating the secret takes effect immediately: pings signed with the old one stop verifying. Update your
                  endpoint's copy right after rotating, and while the two sides disagree acknowledge with a 2xx and
                  reconcile — a 4xx is not retried, so a rejection drops the ping.
                </li>
              </ul>
            </div>

            <p>
              Testing: "Send test ping" in your account settings posts your most recent sale with <Code>test</Code> set to{" "}
              <Code>true</Code>. Refund and dispute pings only fire from real charges. Buying your own product records a test
              purchase with no charge, which cannot be refunded or disputed. To exercise refund, dispute or dispute_won
              handlers without moving money, send a test event to that{" "}
              <a href="/api#resource-subscriptions">resource subscription</a>.
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
