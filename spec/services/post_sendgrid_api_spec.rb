# frozen_string_literal: true

require "spec_helper"

describe PostSendgridApi, :freeze_time do
  include Rails.application.routes.url_helpers

  before do
    @seller = create(:named_user)
    @post = create(:audience_installment, name: "post title", message: "post body", seller: @seller)
    described_class.mails.clear
  end

  def send_emails(**args) = described_class.new(post: @post, **args).send_emails
  def send_default_email = send_emails(recipients: [{ email: "c1@example.com" }])
  def sent_emails = described_class.mails
  def sent_email = sent_emails["c1@example.com"]
  def sent_email_content = sent_email[:content]
  def html_doc(content) = Nokogiri::HTML(content)
  def body_plaintext(content) = html_doc(content).at_xpath("//body").text.strip

  describe "Premailer" do
    before { send_default_email }

    it "automatically inlines styles" do
      expect(sent_email_content).to include("<body style=")
    end
  end

  describe "Seller's design settings" do
    before do
      @post.seller.seller_profile.update!(highlight_color: "#009a49", font: "Roboto Mono", background_color: "#000000")
      send_default_email
    end

    it "includes them as CSS" do
      expect(sent_email_content).to include("body {\nbackground-color: #000000; color: #fff; font-family: \"Roboto Mono\", \"ABC Favorit\", monospace;\n}")
      expect(sent_email_content).to include("body {\nheight: auto; min-height: 100%;\n}")
    end
  end

  describe "preheader text" do
    before { send_default_email }

    it "is included at the start of the email" do
      expect(body_plaintext(sent_email_content)).to start_with("post body")
    end
  end

  describe "call to action button" do
    before do
      @post.update!(call_to_action_url: "https://cta.example/", call_to_action_text: "Click here")
      send_default_email
    end

    it "is included when CTA url and CTA text are set" do
      node = html_doc(sent_email_content).at_xpath(%(//a[@href="https://cta.example/"]))
      expect(node).to be_present
      expect(node.text).to eq("Click here")
    end
  end

  describe "'View Content' button" do
    it "is not included when there are no attachments" do
      send_default_email
      expect(sent_email_content).not_to include("View content")
    end

    it "is included when there are attachments" do
      @post.product_files << create(:product_file)
      url_redirect = create(:url_redirect, installment: @post)
      send_emails(recipients: [{ email: "c1@example.com", url_redirect: }])
      node = html_doc(sent_email_content).at_xpath(%(//a[@href="#{url_redirect.download_page_url}"]))
      expect(node).to be_present
      expect(node.text).to eq("View content")
    end
  end

  describe "Validations" do
    it "raises an error when there are too many recipients" do
      stub_const("#{described_class}::MAX_RECIPIENTS", 2)
      expect do
        send_emails(recipients: [{ email: "c1@example.com" }] * 3)
      end.to raise_error(/too many recipients/i)
    end

    it "raises an error when a recipient has no email" do
      expect do
        send_emails(recipients: [{ email: "" }])
      end.to raise_error(/must have an email/i)
    end

    it "raises an error when a post has files but no url_redirect" do
      @post.product_files << create(:product_file)
      expect do
        send_default_email
      end.to raise_error(/must have a url_redirect/i)
    end

    it "raises an error when recipients have inconsistent records" do
      expect do
        send_emails(recipients: [{ email: "c1@example.com", purchase: create(:purchase), follower: create(:follower) }])
      end.to raise_error(/Recipients can't have .* and\/or .* record/i)

      expect do
        send_emails(recipients: [{ email: "c1@example.com", purchase: create(:purchase), affiliate: create(:direct_affiliate) }])
      end.to raise_error(/Recipients can't have .* and\/or .* record/i)

      expect do
        send_emails(recipients: [{ email: "c1@example.com", follower: create(:follower), affiliate: create(:direct_affiliate) }])
      end.to raise_error(/Recipients can't have .* and\/or .* record/i)
    end
  end

  describe "'Reply with a comment' button" do
    it "is not included when allow_comments=false" do
      send_default_email
      expect(sent_email_content).not_to include("Reply with a comment")
    end

    it "is not included when allow_comments=true and shown_on_profile=false" do
      @post.update!(allow_comments: true, shown_on_profile: false)
      send_default_email
      expect(sent_email_content).not_to include("Reply with a comment")
    end

    it "is included when allow_comments=true and shown_on_profile=true" do
      @post.update!(allow_comments: true, shown_on_profile: true)
      send_default_email

      expected_url = view_post_url(
        username: @post.user.username,
        slug: @post.slug,
        host: UrlService.domain_with_protocol
      )

      node = html_doc(sent_email_content).at_xpath(%(//a[@href="#{expected_url}#comments"]))
      expect(node).to be_present
      expect(node.text).to eq("Reply with a comment")
    end
  end

  describe "Update reason" do # little text in the footer indicating why the recipient got this email
    it "is generic when installment_type='seller'" do
      @post.update!(installment_type: Installment::SELLER_TYPE)
      send_default_email
      expect(sent_email_content).to include("You've received this post because you've purchased a product from #{@post.seller.name}.")
    end

    context "when installment_type='product' or 'variant'" do
      before do
        @product = create(:product, user: @seller)
        @post.update!(installment_type: Installment::PRODUCT_TYPE, link: @product)
      end

      it "mentions when it's due to the subscription being cancelled" do # only workflows
        @product.update!(is_recurring_billing: true)
        @post.update!(workflow_trigger: Installment::MEMBER_CANCELLATION_WORKFLOW_TRIGGER)
        send_default_email
        expect(sent_email_content).to include("You've received this email because you cancelled your membership to <a href=\"#{@post.link.long_url}\">#{@post.link.name}</a>.")

        # similar but different link when there's a url_redirect
        url_redirect = create(:url_redirect, installment: @post)
        send_emails(recipients: [{ email: "c1@example.com", url_redirect: }])
        expect(sent_email_content).to include("You've received this email because you cancelled your membership to <a href=\"#{url_redirect.download_page_url}\">#{@post.link.name}</a>.")
      end

      it "mentions when it's due to it being an active subscription" do
        @product.update!(is_recurring_billing: true)
        send_default_email
        expect(sent_email_content).to include("You've received this email because you subscribed to <a href=\"#{@post.link.long_url}\">#{@post.link.name}</a>.")

        # similar but different link when there's a url_redirect
        url_redirect = create(:url_redirect, installment: @post)
        send_emails(recipients: [{ email: "c1@example.com", url_redirect: }])
        expect(sent_email_content).to include("You've received this email because you subscribed to <a href=\"#{url_redirect.download_page_url}\">#{@post.link.name}</a>.")
      end

      it "mentions when it's due to it being a purchase" do
        send_default_email
        expect(sent_email_content).to include("You've received this email because you've purchased <a href=\"#{@post.link.long_url}\">#{@post.link.name}</a>.")

        # similar but different link when there's a url_redirect
        url_redirect = create(:url_redirect, installment: @post)
        send_emails(recipients: [{ email: "c1@example.com", url_redirect: }])
        expect(sent_email_content).to include("You've received this email because you've purchased <a href=\"#{url_redirect.download_page_url}\">#{@post.link.name}</a>.")
      end
    end
  end

  describe "Unsubscribe link" do
    it "links to purchase unsubscribe page when coming with a purchase" do
      allow_any_instance_of(Purchase).to receive(:secure_external_id).and_return("sample-secure-id")
      purchase = create(:purchase, :from_seller, seller: @seller)
      send_emails(recipients: [{ email: "c1@example.com", purchase: }])

      node = html_doc(sent_email_content).at_xpath(%(//a[@href="#{unsubscribe_purchase_url(purchase.secure_external_id(scope: "unsubscribe"))}"]))
      expect(node).to be_present
      expect(node.text).to eq("Unsubscribe")
    end

    it "links to unfollow page when coming with a follower" do
      follower = create(:follower, user: @seller)
      send_emails(recipients: [{ email: "c1@example.com", follower: }])

      node = html_doc(sent_email_content).at_xpath(%(//a[@href="#{cancel_follow_url(follower.external_id)}"]))
      expect(node).to be_present
      expect(node.text).to eq("Unsubscribe")
    end

    it "links to affiliate unsubscribe page when coming with an affiliate" do
      affiliate = create(:direct_affiliate, seller: @seller)
      send_emails(recipients: [{ email: "c1@example.com", affiliate: }])

      node = html_doc(sent_email_content).at_xpath(%(//a[@href="#{unsubscribe_posts_affiliate_url(affiliate.external_id)}"]))
      expect(node).to be_present
      expect(node.text).to eq("Unsubscribe")
    end
  end

  it "sends the correct text / subject / reply-to" do
    @seller.update!(support_email: "custom@example.com")
    send_default_email

    expect(sent_email[:subject]).to include("post title")
    expect(sent_email[:reply_to]).to include("custom@example.com")
    expect(sent_email_content).to include("post title")
    expect(sent_email_content).to include("post body")
  end

  it "sets the correct custom_args" do
    purchase = create(:purchase, :from_seller, seller: @seller)
    follower = create(:follower, user: @seller)
    affiliate = create(:direct_affiliate, seller: @seller)
    send_emails(recipients: [
                  { email: "c1@example.com", purchase: },
                  { email: "c2@example.com", follower: },
                  { email: "c3@example.com", affiliate: },
                ])

    expect(sent_emails["c1@example.com"][:custom_args]).to eq(
      "seller_id" => @seller.id.to_s,
      "purchase_id" => purchase.id.to_s,
      # the following are required for HandleSendgridEventJob
      "installment_id" => @post.id.to_s,
      "type" => "CreatorContactingCustomersMailer.purchase_installment",
      "identifier" => "[#{purchase.id}, #{@post.id}]",
    )
    expect(sent_emails["c2@example.com"][:custom_args]).to eq(
      "seller_id" => @seller.id.to_s,
      "follower_id" => follower.id.to_s,
      # the following are required for HandleSendgridEventJob
      "installment_id" => @post.id.to_s,
      "type" => "CreatorContactingCustomersMailer.follower_installment",
      "identifier" => "[#{follower.id}, #{@post.id}]",
    )
    expect(sent_emails["c3@example.com"][:custom_args]).to eq(
      "seller_id" => @seller.id.to_s,
      "affiliate_id" => affiliate.id.to_s,
      # the following are required for HandleSendgridEventJob
      "installment_id" => @post.id.to_s,
      "type" => "CreatorContactingCustomersMailer.direct_affiliate_installment",
      "identifier" => "[#{affiliate.id}, #{@post.id}]",
    )
  end

  it "creates EmailInfo record" do
    send_emails(recipients: [
                  { email: "c1@example.com", purchase: create(:purchase) },
                  { email: "c2@example.com" }, # no purchase for this user, so the email_info record won't be created
                ])

    send_emails(recipients: [{ email: "c1@example.com" }])
    expect(EmailInfo.count).to eq(1)
    expect(EmailInfo.first.attributes).to include(
      "type" => "CreatorContactingCustomersEmailInfo",
      "installment_id" => @post.id,
      "email_name" => "purchase_installment",
      "state" => "sent",
      "sent_at" => Time.current,
    )
  end

  it "records the email events" do
    expect(EmailEvent).to receive(:log_send_events).with(["c1@example.com"], Time.current).and_call_original

    send_emails(recipients: [{ email: "c1@example.com" }])
    expect(EmailEvent.first!).to have_attributes(
      "email_digest" => EmailEvent.email_sha_digest("c1@example.com"),
      "sent_emails_count" => 1,
      "last_email_sent_at" => Time.current,
    )
  end

  it "sends push notifications" do
    purchaser = create(:user, email: "c1@example.com")
    purchase = create(:purchase, purchaser:)
    send_emails(recipients: [{ email: "c1@example.com", purchase: }])

    expect(PushNotificationWorker.jobs.size).to eq(1)
    expect(PushNotificationWorker).to have_enqueued_sidekiq_job(
      purchaser.id,
      Device::APP_TYPES[:consumer],
      @post.subject,
      "By #{@post.seller.name}",
      { "installment_id" => @post.external_id, "purchase_id" => purchase.external_id },
    ).on("low")
  end

  it "updates delivery statistics" do
    blast_1 = create(:post_email_blast, post: @post, delivery_count: 0)
    send_emails(recipients: [
                  { email: "c1@example.com" },
                  { email: "c2@example.com" }
                ], blast: blast_1)

    expect(@post.reload.customer_count).to eq(2)
    expect(blast_1.reload.delivery_count).to eq(2)

    blast_2 = create(:post_email_blast, post: @post, delivery_count: 0)
    send_emails(recipients: [
                  { email: "c3@example.com" }
                ], blast: blast_2)

    expect(@post.reload.customer_count).to eq(3)
    expect(blast_2.reload.delivery_count).to eq(1)
  end

  context "when preview email" do
    before do
      create(:user, email: "c1@example.com") # test that the push notifications aren't sent
      send_emails(recipients: [{ email: "c1@example.com" }], preview: true)
    end

    it "sends an email" do
      expect(sent_emails.size).to eq(1)
    end

    it "does not record any info" do
      expect(@post.customer_count).to eq(nil)
      expect(EmailInfo.count).to eq(0)
    end

    it "does not send a push notification" do
      expect(PushNotificationWorker.jobs.size).to eq(0)
    end
  end

  it "includes a link to Gumroad" do
    send_default_email
    node = html_doc(sent_email_content).at_xpath(%(//div[contains(@class, 'footer')]/a[@href="#{root_url}"]))
    expect(node).to be_present
    expect(node.text).to include("Powered by")
  end

  describe "Cache" do
    it "prevents the template from being rendered several times for the same post, across multiple calls" do
      cache = {}
      expect(ApplicationController.renderer).to receive(:render).twice.and_call_original
      send_emails(recipients: [
                    { email: "c1@example.com" },
                    { email: "c2@example.com" }
                  ], cache:)
      send_emails(recipients: [
                    { email: "c3@example.com" },
                    { email: "c4@example.com" }
                  ], cache:)
      send_emails(
        post: create(:post),
        recipients: [
          { email: "c1@example.com" },
          { email: "c2@example.com" }
        ], cache:)
    end
  end
end
