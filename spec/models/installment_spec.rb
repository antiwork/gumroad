# frozen_string_literal: true

require "spec_helper"

describe Installment do
  include Rails.application.routes.url_helpers

  before do
    @creator = create(:named_user, :with_avatar)
    @installment = @post = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.example.com", seller: @creator)
  end

  describe "scopes" do
    describe ".visible_on_profile" do
      it "returns only non-workflow audience type published posts that are shown on profile" do
        create(:installment, :published, installment_type: Installment::FOLLOWER_TYPE, seller: @creator, shown_on_profile: true)
        create(:installment, :published, installment_type: Installment::AUDIENCE_TYPE, seller: @creator)
        create(:installment, :published, installment_type: Installment::AUDIENCE_TYPE, workflow: create(:workflow))
        create(:installment, :published, installment_type: Installment::AUDIENCE_TYPE, seller: @creator, shown_on_profile: true, deleted_at: 1.day.ago)
        post = create(:installment, :published, installment_type: Installment::AUDIENCE_TYPE, seller: @creator, shown_on_profile: true)

        expect(described_class.visible_on_profile).to eq([post])
      end
    end
  end

  describe "#is_downloadable?" do
    it "returns false if post has no files" do
      expect(@installment.is_downloadable?).to eq(false)
    end

    it "returns false if post has only stream-only files" do
      @installment.product_files << create(:streamable_video, stream_only: true)

      expect(@installment.is_downloadable?).to eq(false)
    end

    it "returns true if post has files that are not stream-only" do
      @installment.product_files << create(:readable_document)
      @installment.product_files << create(:streamable_video, stream_only: true)

      expect(@installment.is_downloadable?).to eq(true)
    end
  end

  describe "#send_installment_from_workflow_for_member_cancellation" do
    before do
      @creator1 = create(:user)
      @product1 = create(:subscription_product, user: @creator1)
      @subscription1 = create(:subscription, link: @product1, cancelled_at: 2.days.ago, deactivated_at: 1.day.ago)
      @subscription2 = create(:subscription, link: @product1, cancelled_at: 2.days.ago, deactivated_at: 1.day.ago)
      @workflow1 = create(:workflow, seller: @creator1, link: @product1, workflow_trigger: "member_cancellation")
      @published_installment = create(:published_installment, link: @product1, workflow: @workflow1, workflow_trigger: "member_cancellation")
      @sale1 = create(:purchase, is_original_subscription_purchase: true, link: @product1, subscription: @subscription1, email: "test@gmail.com", created_at: 1.week.ago, price_cents: 100)
      @sale2 = create(:purchase, is_original_subscription_purchase: true, link: @product1, subscription: @subscription2, email: "test2@gmail.com", created_at: 2.weeks.ago, price_cents: 100)
    end

    it "sends a subscription_cancellation_installment email for the cancellation" do
      expect(PostSendgridApi).to receive(:process).with(
        post: @published_installment,
        recipients: [{ email: @sale1.email, purchase: @sale1, subscription: @subscription1 }],
        cache: {}
      )
      @published_installment.send_installment_from_workflow_for_member_cancellation(@subscription1.id)

      # PostSendgridApi creates this, but is mocked in specs
      create(:creator_contacting_customers_email_info_sent, purchase: @sale1, installment: @published_installment, email_name: "subscription_cancellation_installment")

      expect(PostSendgridApi).to receive(:process).with(
        post: @published_installment,
        recipients: [{ email: @sale2.email, purchase: @sale2, subscription: @subscription2 }],
        cache: anything
      )
      @published_installment.send_installment_from_workflow_for_member_cancellation(@subscription2.id)
    end

    it "does not send an email for non member cancellation installments" do
      @published_installment.update!(workflow_trigger: nil)
      expect(PostSendgridApi).not_to receive(:process)
      @published_installment.send_installment_from_workflow_for_member_cancellation(@subscription1.id)
      @published_installment.send_installment_from_workflow_for_member_cancellation(@subscription2.id)
    end

    it "does not send an email for alive subscriptions" do
      @subscription1.update!(cancelled_at: nil, deactivated_at: nil)
      expect(PostSendgridApi).to receive(:process).with(
        post: @published_installment,
        recipients: [{ email: @sale2.email, purchase: @sale2, subscription: @subscription2 }],
        cache: anything
      )

      @published_installment.send_installment_from_workflow_for_member_cancellation(@subscription1.id)
      @published_installment.send_installment_from_workflow_for_member_cancellation(@subscription2.id)
    end

    it "does not send an email if sale's can_contact is set to false" do
      @sale1.update!(can_contact: false)
      expect(PostSendgridApi).to receive(:process).with(
        post: @published_installment,
        recipients: [{ email: @sale2.email, purchase: @sale2, subscription: @subscription2 }],
        cache: anything
      )

      @published_installment.send_installment_from_workflow_for_member_cancellation(@subscription1.id)
      @published_installment.send_installment_from_workflow_for_member_cancellation(@subscription2.id)
    end

    it "does not send an email if sale is chargebacked" do
      @sale1.update!(chargeback_date: 1.days.ago)
      expect(PostSendgridApi).to receive(:process).with(
        post: @published_installment,
        recipients: [{ email: @sale2.email, purchase: @sale2, subscription: @subscription2 }],
        cache: anything
      )

      @published_installment.send_installment_from_workflow_for_member_cancellation(@subscription1.id)
      @published_installment.send_installment_from_workflow_for_member_cancellation(@subscription2.id)
    end

    it "does not send an email if the customer has already received a cancellation email for this installment from the creator" do
      # create 2 products made by the same creator, and two subscriptions by the same customer
      product = create(:subscription_product, user: @creator1)
      subscription = create(:subscription, link: product, cancelled_at: 2.days.ago, deactivated_at: 1.day.ago)
      product2 = create(:subscription_product, user: @creator1)
      subscription2 = create(:subscription, link: product2, cancelled_at: 2.days.ago, deactivated_at: 1.day.ago)
      sale = create(:purchase, is_original_subscription_purchase: true, link: product, subscription:, email: "test@gmail.com", created_at: 1.week.ago, price_cents: 100)
      create(:purchase, is_original_subscription_purchase: true, link: product2, subscription: subscription2, email: "test@gmail.com", created_at: 1.week.ago, price_cents: 100)

      workflow = create(:seller_workflow, seller: @creator1, workflow_trigger: "member_cancellation")
      installment = create(:published_installment, workflow:, workflow_trigger: "member_cancellation")

      # Assume an email's been sent for `subscription`. PostSendgridApi creates this, but is mocked in specs
      create(:creator_contacting_customers_email_info_sent, purchase: sale, installment:, email_name: "subscription_cancellation_installment")

      # Because an email was sent for `subscription`, subscription2's email shouldn't be sent.
      expect(PostSendgridApi).not_to receive(:process)
      installment.send_installment_from_workflow_for_member_cancellation(subscription2.id)
    end

    it "does not send an email if the workflow does not apply to the purchase" do
      creator = create(:user)
      product = create(:subscription_product, user: creator)
      workflow = create(:workflow, seller: creator, link: product, workflow_trigger: "member_cancellation")

      @published_installment.update!(link: product, workflow:)

      expect(PostSendgridApi).not_to receive(:process)
      @published_installment.send_installment_from_workflow_for_member_cancellation(@subscription1.id)
      @published_installment.send_installment_from_workflow_for_member_cancellation(@subscription2.id)
    end
  end

  describe "#truncated_description" do
    before do
      @installment.update!(message: "<h3>I'm a Title.</h3><p>I'm a body. I've got all sorts of punctuation.</p>")
    end

    it "does not escape characters and adds space between paragraphs" do
      expect(@installment.truncated_description).to eq "I'm a Title. I'm a body. I've got all sorts of punctuation."
    end
  end

  describe "#message_with_inline_syntax_highlighting_and_upsells" do
    let(:product) { create(:product, user: @creator, price_cents: 1000) }

    context "with code blocks" do
      before do
        message = <<~HTML
          <p>hello, <code>world</code>!</p>
          <pre class="codeblock-lowlight"><code>// bad
          var a = 1;
          var b = 2;

          // good
          const a = 1;
          const b = 2;</code></pre>
          <p>Ruby code:</p>
          <pre class="codeblock-lowlight"><code class="language-ruby">def hello_world
            puts "Hello, World!"
          end</code></pre>
          <p>TypeScript code:</p>
          <pre class="codeblock-lowlight"><code class="language-typescript">function greet(name: string): void {
            console.log(`Hello, ${name}!`);
          }</code></pre>
          <p>Bye!</p>
        HTML

        @installment.update!(message:)
      end

      it "returns message with inline syntax highlighting the code snippets" do
        expect(@installment.message_with_inline_syntax_highlighting_and_upsells).to eq(%(<p>hello, <code>world</code>!</p>
<pre style="white-space: revert; overflow: auto; border: 1px solid currentColor; border-radius: 4px; background-color: #fff;"><code style="max-width: unset; border-width: 0; width: 100vw; background-color: #fff;">// bad
var a = 1;
var b = 2;

// good
const a = 1;
const b = 2;</code></pre>
<p>Ruby code:</p>
<pre style="white-space: revert; overflow: auto; border: 1px solid currentColor; border-radius: 4px; background-color: #fff;"><code style="max-width: unset; border-width: 0; width: 100vw; background-color: #fff;"><span style="color: #9d0006">def</span> <span style="color: #282828;background-color: #fff">hello_world</span>
  <span style="color: #282828;background-color: #fff">puts</span> <span style="color: #79740e;font-style: italic">"Hello, World!"</span>
<span style="color: #9d0006">end</span></code></pre>
<p>TypeScript code:</p>
<pre style="white-space: revert; overflow: auto; border: 1px solid currentColor; border-radius: 4px; background-color: #fff;"><code style="max-width: unset; border-width: 0; width: 100vw; background-color: #fff;"><span style="color: #af3a03">function</span> <span style="color: #282828;background-color: #fff">greet</span><span style="color: #282828">(</span><span style="color: #282828;background-color: #fff">name</span><span style="color: #282828">:</span> <span style="color: #9d0006">string</span><span style="color: #282828">):</span> <span style="color: #9d0006">void</span> <span style="color: #282828">{</span>
  <span style="color: #282828;background-color: #fff">console</span><span style="color: #282828">.</span><span style="color: #282828;background-color: #fff">log</span><span style="color: #282828">(</span><span style="color: #79740e;font-style: italic">`Hello, </span><span style="color: #282828">${</span><span style="color: #282828;background-color: #fff">name</span><span style="color: #282828">}</span><span style="color: #79740e;font-style: italic">!`</span><span style="color: #282828">);</span>
<span style="color: #282828">}</span></code></pre>
<p>Bye!</p>
))
      end
    end

    context "with upsell cards" do
      before do
        message = <<~HTML
          <p>Check out these products:</p>
          <upsell-card id="#{upsell.external_id}"></upsell-card>
          <p>Great deals!</p>
        HTML

        @installment.update!(message:)
      end

      let(:offer_code) { create(:offer_code, user: @creator, products: [product], amount_cents: 200) }
      let(:upsell) { create(:upsell, product:, seller: @creator, offer_code:) }

      it "renders both regular and discounted upsell cards" do
        result = @installment.message_with_inline_syntax_highlighting_and_upsells

        expect(result).to eq(%(<p>Check out these products:</p>
<div class="item">
  <div class="product-checkout-cell">
    <div class="figure">
        <img alt="The Works of Edgar Gumstein" src="/assets/native_types/thumbnails/digital-d4b2a661e31ec353551a8dae9996b1e75b1e629e363d683aaa5fd2fb1213311c.png">
    </div>
    <div class="section">
      <div class="content">
        <div class="section">
          <h4><a href="http://app.test.gumroad.com:31337/checkout?accepted_offer_id=#{CGI.escape(upsell.external_id)}&amp;product=#{product.unique_permalink}">The Works of Edgar Gumstein</a></h4>
        </div>
        <div class="section">
            <s style="display: inline;">$10</s>
          $8
        </div>
      </div>
    </div>
  </div>
</div>

<p>Great deals!</p>
))
      end
    end

    context "with media embeds" do
      it "replaces media embed iframe with a link to the media thumbnail" do
        @installment.update!(message: %(<div class="tiptap__raw" data-title="Q4 2024 Antiwork All Hands" data-url="https://www.youtube.com/watch?v=drMMDclhgsc" data-thumbnail="https://i.ytimg.com/vi/drMMDclhgsc/maxresdefault.jpg"><div><div style="left: 0; width: 100%; height: 0; position: relative; padding-bottom: 56.25%;"><iframe src="//cdn.iframe.ly/api/iframe?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdrMMDclhgsc&amp;key=31708e31359468f73bc5b03e9dcab7da" style="top: 0; left: 0; width: 100%; height: 100%; position: absolute; border: 0;" allowfullscreen="" scrolling="no" allow="accelerometer *; clipboard-write *; encrypted-media *; gyroscope *; picture-in-picture *; web-share *;"></iframe></div></div></div>))
        expect(@installment.message_with_inline_syntax_highlighting_and_upsells).to eq(%(<p><a href="https://www.youtube.com/watch?v=drMMDclhgsc" target="_blank" rel="noopener noreferrer"><img src="https://i.ytimg.com/vi/drMMDclhgsc/maxresdefault.jpg" alt="Q4 2024 Antiwork All Hands"></a></p>))
      end

      it "replaces media embed iframe with a link to the media's title if thumbnail is missing" do
        @installment.update!(message: %(<div class="tiptap__raw" data-title="Ben Holmes on Twitter / X" data-url="https://twitter.com/BHolmesDev/status/1858141344008405459">\n<div class="iframely-embed" style="max-width: 550px;"><div class="iframely-responsive" style="padding-bottom: 56.25%;"><a href="https://twitter.com/BHolmesDev/status/1858141344008405459" data-iframely-url="//cdn.iframe.ly/api/iframe?url=https%3A%2F%2Fx.com%2Fbholmesdev%2Fstatus%2F1858141344008405459%3Fs%3D46&amp;key=31708e31359468f73bc5b03e9dcab7da"></a></div></div>\n<script async="" src="//cdn.iframe.ly/embed.js" charset="utf-8"></script>\n</div>))
        expect(@installment.message_with_inline_syntax_highlighting_and_upsells).to eq(%(<p><a href="https://twitter.com/BHolmesDev/status/1858141344008405459" target="_blank" rel="noopener noreferrer">Ben Holmes on Twitter / X</a></p>))
      end
    end
  end

  describe "#message_with_inline_abandoned_cart_products" do
    let(:workflow) { create(:abandoned_cart_workflow, seller: @creator) }
    let(:installment) { workflow.installments.first }

    before do
      installment.update!(message: "<p>hello, <code>world</code>!<p>We saved the following items in your cart, so when you're ready to buy, simply <a href='#{checkout_index_url(host: UrlService.domain_with_protocol)}'>complete checking out</a>.</p><product-list-placeholder />")
    end

    context "when products are missing" do
      it "returns the message as it is" do
        expect(installment.message_with_inline_abandoned_cart_products(products: [])).to eq(installment.message)
      end
    end

    context "when products are present" do
      let!(:products) { create_list(:product, 4, user: @creator) }

      it "returns the message with the products" do
        checkout_url = checkout_index_url(host: UrlService.domain_with_protocol)
        message = installment.message_with_inline_abandoned_cart_products(products: workflow.abandoned_cart_products)

        expect(message).to include(@creator.avatar_url)
        parsed_message = Nokogiri::HTML(message)
        expect(message).to include(%(<a target="_blank" href="#{@creator.profile_url}">#{@creator.display_name}</a>))
        products.take(3) do |product|
          expect(parsed_message.at_css("a[target='_blank'][href='#{product.long_url}']").text).to eq(product.name)
        end
        expect(message).to_not include("Product 4")
        expect(message).to_not include("<product-list-placeholder />")
        expect(parsed_message.at_css("a[href='#{checkout_url}']").text).to eq("complete checking out")
        expect(parsed_message.at_css("a[href='#{checkout_url}'][target='_blank']").text).to eq("and 1 more product")
        expect(parsed_message.at_css("a.button.primary[href='#{checkout_url}'][target='_blank']").text).to eq("Complete checkout")
      end

      context "when a custom checkout_url is provided" do
        it "returns the message with the custom checkout_url" do
          checkout_url = checkout_index_url(host: UrlService.domain_with_protocol, cart_id: "abc123")
          message = installment.message_with_inline_abandoned_cart_products(products: workflow.abandoned_cart_products, checkout_url:)
          expect(message).to include("cart_id=abc123")
          parsed_message = Nokogiri::HTML(message)
          expect(parsed_message.at_css("a[href='#{checkout_url}']").text).to eq("complete checking out")
          expect(parsed_message.at_css("a[href='#{checkout_url}'][target='_blank']").text).to eq("and 1 more product")
          expect(parsed_message.at_css("a.button.primary[href='#{checkout_url}'][target='_blank']").text).to eq("Complete checkout")
        end
      end
    end
  end

  describe "#generate_url_redirect_for_subscription" do
    before do
      @subscription = create(:subscription, link: @installment.link)
    end

    it "creates a new url_redirect" do
      @installment.generate_url_redirect_for_subscription(@subscription)
      expect((@installment.url_redirect(@subscription).instance_of? UrlRedirect)).to be(true)
    end
  end

  describe "#url_redirect" do
    before do
      @subscription = create(:subscription, link: @installment.link)
      @installment.generate_url_redirect_for_subscription(@subscription)
    end

    it "returns correct url_redirect" do
      url_redirect = @installment.url_redirect(@subscription)
      expect(url_redirect.subscription).to eq @subscription
      expect(url_redirect.installment).to eq @installment
    end
  end

  describe "#follower_or_audience_url_redirect" do
    it "returns a url_redirect without an associated purchase object" do
      post = create(:post)
      expect(post.follower_or_audience_url_redirect).to eq(nil)

      UrlRedirect.create!(installment: post, subscription: create(:subscription))
      UrlRedirect.create!(installment: post, purchase: create(:purchase))
      url_redirect = UrlRedirect.create!(installment: post)
      UrlRedirect.create!(installment: post, purchase: create(:purchase), subscription: create(:subscription))

      expect(post.reload.follower_or_audience_url_redirect).to eq(url_redirect)
    end
  end

  describe "#download_url" do
    before do
      @product_file = create(:product_file, installment: @installment, link: nil)
      @subscriber = create(:user)
      @subscription = create(:subscription, link: @installment.link, user: @subscriber)
      @purchase = create(:purchase, is_original_subscription_purchase: true, link: @installment.link, subscription: @subscription, price_cents: 100, purchaser: @subscriber)
      @purchase_url_redirect = @installment.generate_url_redirect_for_purchase(@purchase)
    end

    it "returns the purchase url redirect if it cannot find a url redirect using the subscription" do
      expect(@installment.download_url(@subscription, @purchase)).to eq @purchase_url_redirect.url.sub("/r/", "/d/")
    end

    it "creates a new url redirect if none exists for installment with files" do
      user = create(:user)
      subscription = create(:subscription, link: @installment.link, user:)
      purchase = create(:purchase, is_original_subscription_purchase: true, link: @installment.link, subscription:, price_cents: 100, purchaser: user)
      expect(@installment.download_url(subscription, purchase)).to be_present
    end

    it "creates a new url redirect if none exists for installment with files even for installments with send_emails=false" do
      @installment.send_emails = false
      @installment.shown_on_profile = true
      @installment.save!
      user = create(:user)
      subscription = create(:subscription, link: @installment.link, user:)
      purchase = create(:purchase, is_original_subscription_purchase: true, link: @installment.link, subscription:, price_cents: 100, purchaser: user)
      expect(@installment.download_url(subscription, purchase)).to be_present
    end

    it "does not return a download url if the installment is going to a follower and has no files" do
      @installment.product_files.map(&:mark_deleted)
      expect(@installment.download_url(nil, nil)).to eq nil
    end
  end

  describe "#invalidate_cache" do
    before do
      @installment = create(:installment, customer_count: 4)
    end

    it "invalidates the cache and read the updated value" do
      3.times { CreatorEmailOpenEvent.create!(installment_id: @installment.id) }

      # Read once and set the cache
      expect(@installment.unique_open_count).to eq 3

      4.times { CreatorEmailOpenEvent.create!(installment_id: @installment.id) }
      new_unique_open_count = @installment.unique_open_count

      # It should remain 3 as the cache isn't invalidated
      expect(new_unique_open_count).to eq 3

      @installment.invalidate_cache(:unique_open_count)

      expect(@installment.unique_open_count).to eq 7
    end
  end

  describe "#displayed_name" do
    it "returns the installment name" do
      @installment.update_attribute(:name, "welcome")
      expect(@installment.displayed_name).to eq("welcome")
    end

    it "returns the message as the name without html tags" do
      @installment.update_attribute(:name, "")
      @installment.update_attribute(:message, "<p>welcome</p>")
      expect(@installment.displayed_name).to eq("welcome")
    end
  end

  describe "#eligible_purchase_for_user" do
    it "returns the user's purchase that passes filters for the post and hence is eligible to view the attached content" do
      creator = create(:user)
      buyer = create(:user)
      product = create(:product, user: creator)
      category = create(:variant_category, title: "Tier", link: product)
      standard_variant = create(:variant, variant_category: category, name: "Standard")
      premium_variant = create(:variant, variant_category: category, name: "Premium")

      product_post = create(:installment, link: product)
      standard_variant_post = create(:variant_installment, link: product, base_variant: standard_variant)
      premium_variant_post = create(:variant_installment, link: product, base_variant: premium_variant)
      seller_post = create(:seller_installment, seller: creator)
      audience_post = create(:audience_installment, seller: creator)
      follower_post = create(:follower_installment, seller: creator)

      other_product_purchase = create(:purchase, link: create(:product, user: creator), purchaser: buyer)
      product_purchase = create(:purchase, link: product, purchaser: buyer)
      standard_variant_purchase = create(:purchase, link: product, purchaser: buyer)
      standard_variant_purchase.variant_attributes << standard_variant
      premium_variant_purchase = create(:purchase, link: product, purchaser: buyer)
      premium_variant_purchase.variant_attributes << premium_variant

      expect(product_post.eligible_purchase_for_user(buyer)).to eq(product_purchase)
      expect(standard_variant_post.eligible_purchase_for_user(buyer)).to eq(standard_variant_purchase)
      expect(premium_variant_post.eligible_purchase_for_user(buyer)).to eq(premium_variant_purchase)
      expect(seller_post.eligible_purchase_for_user(buyer)).to eq(other_product_purchase)
      expect(audience_post.eligible_purchase_for_user(buyer)).to be(nil)
      expect(follower_post.eligible_purchase_for_user(buyer)).to be(nil)
      expect(follower_post.eligible_purchase_for_user(nil)).to be(nil)
    end
  end

  describe "#targeted_at_purchased_item?" do
    let(:variant) { create(:variant) }
    let(:product) { variant.link }
    let(:purchase) { create(:purchase, link: product, variant_attributes: [variant]) }

    context "product installment" do
      it "returns true if it is targeted at the purchased product" do
        post = build(:installment, link: product)
        expect(post.targeted_at_purchased_item?(purchase)).to eq true
      end

      it "returns false if it is not targeted at the purchased product" do
        post = build(:installment)
        expect(post.targeted_at_purchased_item?(purchase)).to eq false
      end
    end

    context "variant installment" do
      it "returns true if it is targeted at the purchased variant" do
        post = build(:variant_installment, base_variant: variant)
        expect(post.targeted_at_purchased_item?(purchase)).to eq true
      end

      it "returns false if it is not targeted at the purchased variant" do
        post = build(:variant_installment)
        expect(post.targeted_at_purchased_item?(purchase)).to eq false
      end
    end

    context "other installment" do
      it "returns true if bought_products includes the purchased product" do
        seller_post = build(:seller_installment, bought_products: [product.unique_permalink])
        follower_post = build(:follower_installment, bought_products: [product.unique_permalink])
        audience_post = build(:audience_installment, bought_products: [product.unique_permalink])

        expect(seller_post.targeted_at_purchased_item?(purchase)).to eq true
        expect(follower_post.targeted_at_purchased_item?(purchase)).to eq true
        expect(audience_post.targeted_at_purchased_item?(purchase)).to eq true
      end

      it "returns true if bought_variants includes the purchased variant" do
        seller_post = build(:seller_installment, bought_variants: [variant.external_id])
        follower_post = build(:follower_installment, bought_variants: [variant.external_id])
        audience_post = build(:audience_installment, bought_variants: [variant.external_id])

        expect(seller_post.targeted_at_purchased_item?(purchase)).to eq true
        expect(follower_post.targeted_at_purchased_item?(purchase)).to eq true
        expect(audience_post.targeted_at_purchased_item?(purchase)).to eq true
      end

      it "returns false if neither bought_products nor bought_variants are present" do
        seller_post = build(:seller_installment)
        follower_post = build(:follower_installment)
        audience_post = build(:audience_installment)

        expect(seller_post.targeted_at_purchased_item?(purchase)).to eq false
        expect(follower_post.targeted_at_purchased_item?(purchase)).to eq false
        expect(audience_post.targeted_at_purchased_item?(purchase)).to eq false
      end

      it "returns false if bought_products does not include the purchased product" do
        other_product = create(:product)
        seller_post = build(:seller_installment, bought_products: [other_product.unique_permalink])
        follower_post = build(:follower_installment, bought_products: [other_product.unique_permalink])
        audience_post = build(:audience_installment, bought_products: [other_product.unique_permalink])

        expect(seller_post.targeted_at_purchased_item?(purchase)).to eq false
        expect(follower_post.targeted_at_purchased_item?(purchase)).to eq false
        expect(audience_post.targeted_at_purchased_item?(purchase)).to eq false
      end

      it "returns false if bought_variants does not include the purchased variant" do
        other_variant = create(:variant)
        seller_post = build(:seller_installment, bought_variants: [other_variant.external_id])
        follower_post = build(:follower_installment, bought_variants: [other_variant.external_id])
        audience_post = build(:audience_installment, bought_variants: [other_variant.external_id])

        expect(seller_post.targeted_at_purchased_item?(purchase)).to eq false
        expect(follower_post.targeted_at_purchased_item?(purchase)).to eq false
        expect(audience_post.targeted_at_purchased_item?(purchase)).to eq false
      end
    end
  end

  describe "#passes_member_cancellation_checks?" do
    before do
      @creator = create(:user, name: "dude")
      @product = create(:subscription_product, user: @creator)
      @subscription = create(:subscription, link: @product)
      @sale = create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription)
      @installment = create(:installment, name: "My first installment", link: @product, workflow_trigger: "member_cancellation")
    end

    it "returns true if the workflow trigger is not a member cancellation" do
      @installment.update!(workflow_trigger: nil)
      expect(@installment.passes_member_cancellation_checks?(@sale)).to eq(true)
    end

    it "returns false if purchase is nil" do
      expect(@installment.passes_member_cancellation_checks?(nil)).to eq(false)
    end

    it "returns false if the email hasn't been sent for the member cancellation" do
      expect(@installment.passes_member_cancellation_checks?(@sale)).to eq(false)
    end

    it "returns true if the email has been sent for the member cancellation" do
      create(:creator_contacting_customers_email_info_sent, purchase: @sale, installment: @installment)
      expect(@installment.passes_member_cancellation_checks?(@sale)).to eq(true)
    end
  end

  describe "#full_url" do
    before do
      @post = create(:audience_installment)
    end

    context "when slug is not present" do
      it "returns nil" do
        @post.update_column(:slug, "")

        expect(@post.full_url).to be_nil
      end
    end

    context "when purchase_id is present" do
      it "returns the subdomain URL of the post" do
        target_url = Rails.application.routes.url_helpers.custom_domain_view_post_url(
          host: @post.user.subdomain_with_protocol,
          slug: @post.slug,
          purchase_id: 1234
        )

        expect(@post.full_url(purchase_id: 1234)).to eq target_url
      end
    end

    context "when purchase_id is not present" do
      it "returns the subdomain URL of the post" do
        target_url = Rails.application.routes.url_helpers.custom_domain_view_post_url(
          host: @post.user.subdomain_with_protocol,
          slug: @post.slug
        )

        expect(@post.full_url).to eq target_url
      end
    end
  end

  describe "#display_type" do
    subject(:display_type) { installment.display_type }

    context "when post published" do
      let(:installment) { create(:published_installment) }

      it "returns 'published'" do
        expect(display_type).to eq("published")
      end
    end

    context "when post is scheduled" do
      let(:installment) { create(:scheduled_installment) }

      it "returns 'scheduled'" do
        expect(display_type).to eq("scheduled")
      end
    end

    context "when post is a draft" do
      let(:installment) { create(:installment) }

      it "returns 'draft'" do
        expect(display_type).to eq("draft")
      end
    end
  end

  describe "#eligible_purchase?" do
    context "when purchase is nil" do
      subject(:installment) { create(:published_installment) }

      it "returns false" do
        expect(installment.eligible_purchase?(nil)).to eq(false)
      end
    end

    context "when installment does not need purchase to access content" do
      subject(:installment) { create(:published_installment, installment_type: "audience") }

      it "returns true" do
        expect(installment.eligible_purchase?(nil)).to eq(true)
      end
    end

    context "when installment is a product post" do
      let(:product) { create(:product) }
      subject(:installment) { create(:product_installment, link: product, published_at: 1.day.ago) }

      context "when purchased product is a post's product" do
        let(:purchase) { create(:purchase, link: product, created_at: 1.second.ago) }

        it "returns true" do
          expect(installment.eligible_purchase?(purchase)).to eq(true)
        end
      end

      context "when purchased product is not a post's product" do
        let(:purchase) { create(:purchase, link: create(:product), created_at: 1.second.ago) }

        it "returns false" do
          expect(installment.eligible_purchase?(purchase)).to eq(false)
        end
      end
    end

    context "when installment is a variant post" do
      let(:product) { create(:product) }
      let!(:variant_category) { create(:variant_category, link: product) }
      let!(:standard_variant) { create(:variant, variant_category:, name: "Standard") }
      let!(:premium_variant) { create(:variant, variant_category:, name: "Premium") }
      subject(:installment) { create(:variant_installment, link: product, published_at: 1.day.ago, base_variant: premium_variant) }

      context "when post's base variant matches with purchase's variants" do
        let(:purchase) { create(:purchase, link: product, variant_attributes: [premium_variant], created_at: 1.second.ago) }

        it "returns true" do
          expect(installment.eligible_purchase?(purchase)).to eq(true)
        end
      end

      context "when post's base variant does not match with purchase's variants" do
        let(:purchase) { create(:purchase, link: product, variant_attributes: [standard_variant], created_at: 1.second.ago) }

        it "returns false" do
          expect(installment.eligible_purchase?(purchase)).to eq(false)
        end
      end
    end

    context "when installment is a seller post" do
      let(:creator) { create(:user) }
      let(:product) { create(:product, user: creator) }
      subject(:installment) { create(:seller_installment, seller: creator, published_at: 1.day.ago) }

      context "when purchased product's creator is a post's creator" do
        let(:purchase) { create(:purchase, link: product, created_at: 1.second.ago) }

        it "returns true" do
          expect(installment.eligible_purchase?(purchase)).to eq(true)
        end
      end

      context "when purchased product's creator is not a post's creator" do
        let(:purchase) { create(:purchase, link: create(:product, user: create(:user)), created_at: 1.second.ago) }

        it "returns false" do
          expect(installment.eligible_purchase?(purchase)).to eq(false)
        end
      end
    end

    context "when installment is a follower post" do
      let(:creator) { create(:user) }
      let(:product) { create(:product, user: creator) }
      let(:installment) { create(:follower_installment, seller: creator, published_at: 1.day.ago) }
      let(:purchase) { create(:purchase, link: product, created_at: 1.second.ago) }

      it "returns true" do
        expect(installment.eligible_purchase?(purchase)).to eq(true)
      end
    end

    context "when installment is an affiliate post" do
      let(:creator) { create(:user) }
      let(:direct_affiliate) { create(:direct_affiliate, affiliate_user: create(:affiliate_user), seller: creator, affiliate_basis_points: 1500, apply_to_all_products: true) }
      let(:product) { create(:product, user: creator) }
      let(:installment) { create(:affiliate_installment, seller: creator, published_at: 1.day.ago) }
      let(:purchase) { create(:purchase, link: product, purchaser: direct_affiliate.affiliate_user, created_at: 1.second.ago) }

      it "returns true" do
        expect(installment.eligible_purchase?(purchase)).to eq(true)
      end
    end
  end

  describe "#publish!" do
    it "publishes the installment" do
      expect do
        @installment.publish!
      end.to change { @installment.published_at }.from(nil).to(be_within(1.second).of(Time.current))
    end

    it "sets the 'published_at' to the optionally provided 'published_at' argument" do
      published_at = 5.minutes.ago.round
      expect do
        @installment.publish!(published_at:)
      end.to change { @installment.published_at }.from(nil).to(published_at)
    end

    it "sets 'workflow_installment_published_once_already' to true if it's a workflow installment" do
      expect do
        @installment.publish!
      end.not_to change { @installment.workflow_installment_published_once_already }

      @installment.update!(workflow: create(:workflow))
      expect do
        @installment.publish!
      end.to change { @installment.workflow_installment_published_once_already }.from(false).to(true)
    end

    context "when the user has not confirmed their email address" do
      before do
        @creator.update!(confirmed_at: nil)
      end

      it "raises an Installment::InstallmentInvalid error" do
        expect do
          @installment.publish!
        end.to raise_error(Installment::InstallmentInvalid)
        expect(@installment.reload.published_at).to be(nil)
        expect(@installment.errors.full_messages.to_sentence).to eq("You have to confirm your email address before you can do that.")
      end
    end
  end

  describe "#is_affiliate_product_post?" do
    before do
      @affiliate_installment = create(:affiliate_installment)
    end

    it "returns false when it is not an affiliate installment" do
      expect(@installment.is_affiliate_product_post?).to eq(false)
    end

    it "returns false when it does not have exactly one affiliate product" do
      expect(@affiliate_installment.is_affiliate_product_post?).to eq(false)
      @affiliate_installment.update!(affiliate_products: ["p1", "p2"])
      expect(@affiliate_installment.is_affiliate_product_post?).to eq(false)
    end

    it "returns true when it is an affiliate installment that has exactly one affiliate product" do
      @affiliate_installment.update!(affiliate_products: ["p"])
      expect(@affiliate_installment.is_affiliate_product_post?).to eq(true)
    end
  end

  describe "#affiliate_product_name" do
    it "returns nil when it is not an affiliate installment" do
      expect(@installment.affiliate_product_name).to eq(nil)
    end

    it "returns the associated affiliate product's name" do
      product = create(:product)
      affiliate_installment = create(:affiliate_installment, affiliate_products: [product.unique_permalink], link: product)
      expect(affiliate_installment.affiliate_product_name).to eq(product.name)
    end
  end

  describe "#audience_members_filter_params" do
    # the actual filtering is tested in audience_member_spec.rb
    it "converts post filters into AudienceMember filters" do
      %w[product seller variant].each do |type|
        @post.update_column(:installment_type, type)
        expect(@post.audience_members_filter_params).to eq(type: "customer")
      end

      %w[follower affiliate].each do |type|
        @post.update_column(:installment_type, type)
        expect(@post.audience_members_filter_params).to eq(type:)
      end

      @post.update_column(:installment_type, "audience")
      expect(@post.audience_members_filter_params).to eq({})

      product_1, product_2 = create_list(:product, 2, user: @post.seller)
      variant_1 = create(:variant, variant_category: create(:variant_category, link: product_1))
      variant_2 = create(:variant, variant_category: create(:variant_category, link: product_2))

      @post.update!(
        bought_products: [product_1.unique_permalink],
        bought_variants: [variant_1.external_id],
        not_bought_products: [product_2.unique_permalink],
        not_bought_variants: [variant_2.external_id],
        paid_more_than_cents: 100,
        paid_less_than_cents: 500,
        created_after: "2020-01-01",
        created_before: "2021-12-31",
        bought_from: "Canada",
        affiliate_products: [product_1.unique_permalink],
      )
      expected_params = {
        bought_product_ids: [product_1.id],
        bought_variant_ids: [variant_1.id],
        not_bought_product_ids: [product_2.id],
        not_bought_variant_ids: [variant_2.id],
        paid_less_than_cents: 500,
        paid_more_than_cents: 100,
        created_after: "2020-01-01T00:00:00-08:00",
        created_before: "2021-12-31T23:59:59-08:00",
        bought_from: "Canada",
        affiliate_product_ids: [product_1.id],
      }
      expect(@post.audience_members_filter_params).to eq(expected_params)
    end
  end

  describe "#audience_members_count" do
    it "returns the number of audience members" do
      expect(@post.audience_members_count).to eq(0)
      create_list(:purchase, 2, :from_seller, seller: @post.seller)
      expect(@post.audience_members_count).to eq(2)
      expect(@post.audience_members_count(1)).to eq(1) # supports a limit, for extra performance
    end
  end

  describe "#send_preview_email" do
    let(:recipient) { create(:user) }

    it "raises an error if the recipient has not confirmed their email address" do
      recipient.update!(email: Faker::Internet.email)
      expect(PostSendgridApi).not_to receive(:process)
      expect do
        @post.reload.send_preview_email(recipient)
      end.to raise_error(Installment::PreviewEmailError)
    end

    it "sends an email to the recipient" do
      expect(PostSendgridApi).to receive(:process).with(
        post: @post,
        recipients: [{ email: recipient.email }],
        preview: true,
      )
      @post.send_preview_email(recipient)
    end

    it "creates a UrlRedirect and sends an email to the recipient when the post has files" do
      @post.product_files << create(:readable_document)
      allow(PostSendgridApi).to receive(:process)

      expect do
        @post.send_preview_email(recipient)
      end.to change { UrlRedirect.count }.by(1)

      # does not recreate a UrlRedirect if it exists already
      expect do
        @post.send_preview_email(recipient)
      end.not_to change { UrlRedirect.count }

      expect(PostSendgridApi).to have_received(:process).with(
        post: @post,
        recipients: [{ email: recipient.email, url_redirect: UrlRedirect.last! }],
        preview: true,
      ).twice
    end

    context "when post has 'abandoned_cart' type" do
      before { @post.update!(installment_type: "abandoned_cart") }

      it "sends abandoned cart preview email" do
        expect do
          @post.send_preview_email(recipient)
        end.to have_enqueued_mail(CustomerMailer, :abandoned_cart_preview).with(recipient.id, @post.id)
      end
    end
  end

  describe "#can_be_blasted?" do
    it "returns true when send_emails = true and no blasts already exist" do
      expect(@post.can_be_blasted?).to eq(true)

      @post.update!(send_emails: false, shown_on_profile: true)
      expect(@post.can_be_blasted?).to eq(false)

      @post.update!(send_emails: true)
      create(:blast, post: @post)
      expect(@post.can_be_blasted?).to eq(false)
    end
  end

  describe ".receivable_by_customers_of_product" do
    it "returns posts that the customers of a given product would receive" do
      product = create(:product)
      product2 = create(:product)
      variant_category = create(:variant_category, link: product)
      variant1 = create(:variant, variant_category: variant_category)
      variant2 = create(:variant, variant_category: variant_category)
      _follower_post = create(:follower_post, :published)
      variant1_post = create(:variant_post, seller: product.user, bought_variants: [variant1.external_id], published_at: 5.days.ago)
      variant2_post = create(:variant_post, seller: product.user, bought_variants: [variant2.external_id], published_at: 2.hours.ago)
      seller_post = create(:seller_post, seller: product.user, bought_products: [product.unique_permalink, create(:product).unique_permalink], published_at: 6.days.ago)
      _seller_post2 = create(:seller_post, :published, seller: product2.user, bought_products: [product2.unique_permalink], bought_variants: [create(:variant).external_id])
      seller_post_for_customers_of_all_products = create(:seller_post, seller: product.user, published_at: 3.hours.ago)
      product_post = create(:product_post, link: product, bought_products: [product.unique_permalink], published_at: 3.days.ago)
      _unpublished_product_post = create(:product_post, link: product, bought_products: [product.unique_permalink])
      _audience_post = create(:audience_post, :published, seller: product.user, bought_products: [product.unique_permalink])
      _affiliate_post = create(:affiliate_post, :published, affiliate_products: [product.unique_permalink])
      product_workflow = create(:product_workflow, seller: product.user, link: product, published_at: 1.day.ago, bought_products: [product.unique_permalink])
      product_workflow_post1 = create(:workflow_installment, workflow: product_workflow, link: product, published_at: 1.day.ago, bought_products: [product.unique_permalink])
      product_workflow_post2 = create(:workflow_installment, workflow: product_workflow, link: product, published_at: 1.day.ago, bought_products: [product.unique_permalink])
      product_workflow_post2.installment_rule.update!(delayed_delivery_time: 5.hours.to_i)
      affiliate_workflow = create(:affiliate_workflow, seller: product.user, link: product, published_at: 1.day.ago, affiliate_products: [product.unique_permalink])
      _affiliate_workflow_post = create(:workflow_installment, :published, workflow: affiliate_workflow, link: product, affiliate_products: [product.unique_permalink])

      expect(described_class.receivable_by_customers_of_product(product:, variant_external_id: nil)).to eq([
                                                                                                             product_workflow_post2, # Sent 5 hours after purchase
                                                                                                             product_workflow_post1, # Sent immediately after purchase
                                                                                                             variant2_post, # Published 2 hours ago
                                                                                                             seller_post_for_customers_of_all_products, # Published 3 hours ago
                                                                                                             product_post, # Published 3 days ago
                                                                                                             variant1_post, # Published 5 days ago
                                                                                                             seller_post, # Published 6 days ago
                                                                                                           ])
      expect(described_class.receivable_by_customers_of_product(product: product, variant_external_id: variant1.external_id)).to eq([
                                                                                                                                      product_workflow_post2, # Sent 5 hours after purchase
                                                                                                                                      product_workflow_post1, # Sent immediately after purchase
                                                                                                                                      seller_post_for_customers_of_all_products, # Published 3 hours ago
                                                                                                                                      product_post, # Published 3 days ago
                                                                                                                                      variant1_post, # Published 5 days ago
                                                                                                                                      seller_post, # Published 6 days ago
                                                                                                                                    ])

      expect(described_class.receivable_by_customers_of_product(product: product, variant_external_id: variant2.external_id)).to eq([
                                                                                                                                      product_workflow_post2, # Sent 5 hours after purchase
                                                                                                                                      product_workflow_post1, # Sent immediately after purchase
                                                                                                                                      variant2_post, # Published 2 hours ago
                                                                                                                                      seller_post_for_customers_of_all_products, # Published 3 hours ago
                                                                                                                                      product_post, # Published 3 days ago
                                                                                                                                      seller_post, # Published 6 days ago
                                                                                                                                    ])
    end
  end

  describe "#trigger_iffy_ingest" do
    let!(:installment) { create(:installment, name: "Original Name", message: "Original Message") }

    it "does not trigger an iffy ingest job if neither name nor message have changed" do
      expect do
        installment.update!(published_at: Time.current)
      end.not_to change { Iffy::Post::IngestJob.jobs.size }
    end

    it "triggers an iffy ingest job if the name has changed" do
      expect do
        installment.update!(name: "New Name")
      end.to change { Iffy::Post::IngestJob.jobs.size }.by(1)
    end

    it "triggers an iffy ingest job if the message has changed" do
      expect do
        installment.update!(message: "New Message")
      end.to change { Iffy::Post::IngestJob.jobs.size }.by(1)
    end
  end

  describe "#featured_image_url" do
    let(:installment) { create(:installment) }

    it "returns nil when message is blank" do
      installment.message = ""
      expect(installment.featured_image_url).to be_nil

      installment.message = nil
      expect(installment.featured_image_url).to be_nil
    end

    it "only returns the first element's image src if it's a figure" do
      installment.message = <<~HTML
        <figure>
          <img src='https://example.com/first.jpg' alt='First'>
          <img src='https://example.com/second.jpg' alt='Second'>
        </figure>
      HTML
      expect(installment.featured_image_url).to eq("https://example.com/first.jpg")

      installment.message = <<~HTML
        <p>First paragraph</p>
        <figure>
          <img src='https://example.com/image.jpg' alt='Test'>
        </figure>
      HTML
      expect(installment.featured_image_url).to be_nil

      installment.message = "text only"
      expect(installment.featured_image_url).to be_nil
    end
  end

  describe "#tags" do
    let(:installment) { create(:installment) }

    it "returns empty array when message is blank" do
      installment.message = ""
      expect(installment.tags).to eq([])

      installment.message = nil
      expect(installment.tags).to eq([])

      installment.message = "   "
      expect(installment.tags).to eq([])
    end

    it "only returns tags from the last element if it's a paragraph" do
      installment.message = <<~HTML
        <p>First paragraph</p>
        <p>#tag1 #tag2 #tag3</p>
      HTML
      expect(installment.tags).to eq(["Tag1", "Tag2", "Tag3"])

      installment.message = <<~HTML
        <p>#tag1 #tag2</p>
        <div>#not #tags</div>
      HTML
      expect(installment.tags).to eq([])

      installment.message = "#not #tags"
      expect(installment.tags).to eq([])
    end

    it "returns tags when all words in the last paragraph start with #" do
      installment.message = <<~HTML
        <p>#RubyOnRails #Tips&Tricks</p>
      HTML
      expect(installment.tags).to eq(["Ruby On Rails", "Tips & Tricks"])

      installment.message = <<~HTML
        <p>Some content here</p>
        <p>#Dedupe #Dedupe</p>
      HTML
      expect(installment.tags).to eq(["Dedupe"])

      installment.message = <<~HTML
        <p>Content</p>
        <p>Not all #tags</p>
      HTML
      expect(installment.tags).to eq([])
    end
  end

  describe "#message_snippet" do
    let(:installment) { create(:installment) }

    it "returns empty string when message is blank" do
      installment.message = ""
      expect(installment.message_snippet).to eq("")

      installment.message = nil
      expect(installment.message_snippet).to eq("")

      installment.message = "   "
      expect(installment.message_snippet).to eq("")
    end

    it "strips HTML tags from message" do
      installment.message = "<p>Hello <strong>world</strong>!</p><br><div>Another paragraph</div>"
      expect(installment.message_snippet).to eq("Hello world! Another paragraph")
    end

    it "squishes extra whitespace" do
      installment.message = "  Hello    world  \n\n  with   extra    spaces  "
      expect(installment.message_snippet).to eq("Hello world with extra spaces")
    end

    it "truncates to 200 characters with word boundaries" do
      installment.message = "a " * 105
      expect(installment.message_snippet).to eq("a " * 98 + "a...")
    end
  end
end
