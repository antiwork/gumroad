# frozen_string_literal: true

class FeaturesMarkdownGenerator
  FEATURES_URL = "https://gumroad.com/features"

  def self.call
    new.call
  end

  def call
    <<~MARKDOWN
      # Gumroad features

      > For the full visual experience, visit [gumroad.com/features](#{FEATURES_URL}).
      > Source code: [github.com/antiwork/gumroad](https://github.com/antiwork/gumroad)

      ## Products

      - **Digital products** — Sell ebooks, audiobooks, software, music, videos, and any downloadable file.
      - **Courses** — Create and sell structured online courses with a built-in content editor.
      - **Memberships** — Offer recurring subscriptions with tiered pricing and member-only content.
      - **Physical products** — Sell physical goods with built-in shipping destination management.
      - **Bundles** — Package multiple products together and sell them at a combined price.
      - **Commissions** — Accept paid commissions for custom work directly through your profile.
      - **Consultation calls** — Sell scheduled calls with built-in availability and calendar integration.
      - **Coffee / tips** — Accept one-time tips and "buy me a coffee" payments from supporters.
      - **Preorders** — Let buyers purchase upcoming products before they launch.
      - **Newsletters** — Publish and monetize email newsletters.
      - **Podcasts** — Host and sell access to premium podcast content.

      ## Pricing & variants

      - **Pay what you want** — Let buyers choose their own price above a minimum you set.
      - **Product variants** — Offer multiple versions, tiers, or options (size, format, license type) for a single product.
      - **SKU management** — Track inventory with unique SKUs for each product variant.
      - **Versioned files** — Upload new versions of product files; buyers get automatic access to updates.

      ## Payments & checkout

      - **Multi-currency support** — Accept payments in dozens of currencies worldwide.
      - **Automatic sales tax, VAT, and GST** — Tax is calculated, collected, and reported automatically based on the buyer's location.
      - **Pay in installments** — Let buyers split payments into scheduled installments.
      - **Stripe payments** — Accept credit and debit card payments via Stripe.
      - **PayPal payments** — Offer PayPal as an alternative payment method at checkout.
      - **Apple Pay and Google Pay** — Support mobile wallet payments for faster checkout.
      - **Discount codes** — Create percentage or fixed-amount discount codes for your products.
      - **Automatic default discount codes** — Automatically apply discount codes to eligible carts.
      - **Purchasing power parity** — Offer location-based discounts so buyers in lower-income countries can afford your products.
      - **Upsells** — Suggest additional products during checkout to increase average order value.
      - **Free trials** — Let buyers try a membership or subscription before being charged.
      - **Cart** — Buyers can add multiple products from the same seller and check out in one transaction.
      - **Custom checkout fields** — Collect extra information from buyers at checkout (e.g., company name, license details).
      - **Refunds** — Issue full or partial refunds directly from your dashboard.
      - **Refund policies** — Set product-level or seller-level refund policies displayed to buyers.
      - **Gifting** — Buyers can purchase products as gifts for someone else.

      ## Payouts

      - **Flexible payout schedule** — Get paid instantly, daily, weekly, monthly, or quarterly.
      - **Multiple payout methods** — Receive payouts to a bank account, debit card, or PayPal.
      - **190+ countries** — Payouts are supported in over 190 countries with country-specific bank integrations.
      - **Country-specific payout thresholds** — Minimum payout amounts adjusted by country.
      - **Instant payouts** — Request an immediate transfer of your available balance.
      - **Payout transaction details via API** — Access granular transaction-level data for each payout through the API.
      - **Global sales tax summary report** — Download a consolidated report of all sales tax collected across jurisdictions.

      ## Content & delivery

      - **Built-in rich content editor** — Create product pages, posts, and course content with a block-based editor supporting text, images, video, and file embeds.
      - **File hosting** — Upload and deliver files of any type (PDF, ZIP, audio, video, etc.) to buyers.
      - **Video hosting and transcoding** — Upload videos that are automatically transcoded for streaming with subtitle support.
      - **Stamped PDFs** — Automatically watermark PDF files with the buyer's information to discourage piracy.
      - **License keys** — Generate and manage license keys for software products with verify, enable, disable, and rotate endpoints.
      - **Multi-seat licenses** — Sell license keys that support multiple activations for teams.
      - **Streaming** — Deliver audio and video content via streaming instead of direct download.

      ## Profile & discovery

      - **Profile page builder** — Customize your seller profile with sections for products, posts, rich text, featured products, wishlists, and email signup.
      - **Custom domains** — Use your own domain name for your Gumroad storefront.
      - **Discover marketplace** — List your products on Gumroad's public marketplace for organic discovery.
      - **Wishlists** — Curate and share themed collections of products.
      - **Product tags and taxonomies** — Categorize your products to help buyers find them.
      - **Followers** — Buyers can follow your profile to get notified about new products and posts.
      - **Top Creator badge** — Earn a badge recognizing you as a top-performing seller on Gumroad.
      - **Product reviews** — Buyers can leave star ratings and written reviews, with optional video reviews.
      - **Testimonials** — Display social proof from customer reviews on your product pages.
      - **Staff picks** — Curated products highlighted by the Gumroad team.

      ## Marketing & engagement

      - **Email marketing** — Send broadcast emails, scheduled emails, and targeted campaigns to your audience for free.
      - **Email drip campaigns** — Automatically send a sequence of emails to new subscribers or buyers on a schedule.
      - **Abandoned cart emails** — Automatically email buyers who started checkout but didn't complete their purchase.
      - **Audience segmentation** — Target emails to specific groups based on purchase history and engagement.
      - **Embeddable email signup form** — Add an email signup form to any website to grow your mailing list.
      - **Workflow automations** — Trigger automated actions (emails, integrations) based on events like new purchases or member cancellations.
      - **Affiliates** — Let others earn commissions by promoting your products with tracked referral links.
      - **Self-service affiliate signup** — Allow affiliates to request to promote your products without manual approval.
      - **Collaborators** — Share revenue with co-creators who contribute to a product.
      - **Product recommendations** — Suggest related products to buyers after purchase.

      ## Integrations

      - **Discord integration** — Automatically invite buyers to a private Discord server or role.
      - **Circle integration** — Grant buyers access to your Circle community.
      - **Zoom integration** — Schedule Zoom calls automatically for consultation products.
      - **Google Calendar integration** — Sync consultation availability with Google Calendar.
      - **Embeddable widgets and overlays** — Embed buy buttons, product cards, and checkout overlays on any website with a JavaScript snippet.
      - **Third-party analytics** — Add your own Google Analytics, Facebook Pixel, or other tracking scripts.
      - **IFTTT** — Connect Gumroad events to thousands of other apps via IFTTT.
      - **Notion** — Unfurl Gumroad links in Notion workspaces.

      ## Analytics & reporting

      - **Sales and traffic analytics** — Track revenue, views, conversions, and traffic sources over time.
      - **UTM tracking** — Create tracked links with UTM parameters and see which campaigns drive sales.
      - **Churn analytics** — Monitor subscription cancellation rates and understand why members leave.
      - **Email analytics** — Track open rates, click rates, and engagement for your email campaigns.
      - **CSV exports** — Export sales data, customer lists, and reports as CSV files.
      - **Consumption analytics** — See how buyers engage with your content (views, downloads, progress).

      ## Admin & developer tools

      - **Team access** — Invite team members with role-based permissions to manage your account.
      - **REST API (v2)** — Full API for managing products, sales, subscribers, and payouts programmatically.
      - **OAuth applications** — Build third-party apps that integrate with Gumroad using OAuth2.
      - **Webhooks** — Receive real-time HTTP notifications when sales, refunds, cancellations, and other events occur.
      - **Open source** — Gumroad's codebase is open source at [github.com/antiwork/gumroad](https://github.com/antiwork/gumroad).
      - **Native mobile app** — Manage your store, view analytics, and respond to customers from iOS and Android.
      - **Two-factor authentication** — Secure your account with TOTP-based two-factor authentication.
      - **Customizable receipts** — Customize the receipt emails sent to your buyers after purchase.

      ## Subscriptions & memberships

      - **Recurring billing** — Charge buyers on a recurring schedule (monthly, quarterly, yearly, or custom).
      - **Tiered memberships** — Offer multiple membership levels with different benefits and prices.
      - **Free trials** — Give new members a trial period before billing starts.
      - **Transparent subscription restarts** — Cancelled members can resubscribe seamlessly with full transparency.
      - **Gifted memberships** — Buyers can gift memberships that appear in the recipient's library.
      - **Subscription management** — Members can upgrade, downgrade, pause, or cancel their subscriptions.

      ---

      *Last updated: #{Date.current.strftime("%B %-d, %Y")}*
      *Visit [gumroad.com/features](#{FEATURES_URL}) for the full interactive feature page.*
    MARKDOWN
  end
end
