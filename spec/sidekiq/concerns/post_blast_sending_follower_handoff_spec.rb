# frozen_string_literal: true

require "spec_helper"

# A follow can end between the audience load and the provider call: the blast's members, the rendered request
# and the provider call are minutes apart. These run the real senders down to the SDK entry points, taking the
# provider branch, so the assertion is on what the provider would have been handed.
describe PostBlastSending, "handing a post to the provider only while the follow lasts" do
  include Rails.application.routes.url_helpers
  _routes.default_url_options = Rails.application.config.action_mailer.default_url_options

  before do
    @seller = create(:named_user)
    @requests = []
    endpoint = double("SendGrid mail send")
    allow(endpoint).to receive(:post) do |request_body:|
      personalizations = request_body["personalizations"]
      @requests << { provider: "sendgrid", to: personalizations.map { _1["to"][0]["email"] }, custom_args: personalizations.map { _1["custom_args"] },
                     unsubscribe_urls: personalizations.map { _1["substitutions"]["{{unsubscribe_url}}"] } }
      double(status_code: 202, body: "")
    end
    allow(SendGrid::API).to receive(:new).and_return(double(client: double(mail: double(_: endpoint))))
    [Resend::Batch, Resend::Emails].each do |sdk|
      allow(sdk).to receive(:send) do |payload|
        @requests << { provider: "resend", to: Array.wrap(payload).flat_map { _1[:to] } }
        double(success?: true, body: "")
      end
    end
  end

  def send_blast(post)
    blast = create(:blast, :just_requested, post:)
    allow(Rails.env).to receive(:test?).and_return(false)
    SendPostBlastEmailsJob.new.perform(blast.id)
    blast.reload
  end

  def unfollow_before_the_provider_slice(follower)
    allow_any_instance_of(SendPostBlastEmailsJob).to receive(:send_provider_slice).and_wrap_original do |original, **kwargs|
      follower.mark_deleted! unless follower.reload.deleted?
      original.call(**kwargs)
    end
  end

  # After the request body exists, which is when the old code had nothing left to check.
  def unfollow_once_the_request_is_built(follower)
    allow_any_instance_of(PostSendgridApi).to receive(:build_mail).and_wrap_original do |original|
      request_body = original.call
      follower.mark_deleted!
      request_body
    end
  end

  def requested_addresses = @requests.flat_map { _1[:to] }.sort

  it "keeps a follower who unfollowed after the audience load out of the SendGrid request" do
    leaver = create(:active_follower, user: @seller, email: "leaver@example.com")
    create(:active_follower, user: @seller, email: "stayer@example.com")
    post = create(:follower_post, :published, seller: @seller)
    unfollow_before_the_provider_slice(leaver)

    blast = send_blast(post)

    expect(@requests.map { _1[:provider] }).to eq(["sendgrid"])
    expect(requested_addresses).to eq(["stayer@example.com"])
    expect(SentPostEmail.where(post:).pluck(:email)).to eq(["stayer@example.com"])
    expect(blast.delivery_count).to eq(1)
    expect(blast.completed_at).to be_present
  end

  it "keeps a follower who unfollowed after the audience load out of the Resend request" do
    Feature.activate(:use_resend_for_post_emails)
    Feature.activate_user(:force_resend_for_post_emails, @seller)
    leaver = create(:active_follower, user: @seller, email: "leaver@example.com")
    create(:active_follower, user: @seller, email: "stayer@example.com")
    post = create(:follower_post, :published, seller: @seller)
    unfollow_before_the_provider_slice(leaver)

    blast = send_blast(post)

    expect(@requests.map { _1[:provider] }).to eq(["resend"])
    expect(requested_addresses).to eq(["stayer@example.com"])
    expect(SentPostEmail.where(post:).pluck(:email)).to eq(["stayer@example.com"])
    expect(blast.delivery_count).to eq(1)
  ensure
    Feature.deactivate(:use_resend_for_post_emails)
  end

  it "keeps a follower who unfollowed while the request was being built out of it" do
    leaver = create(:active_follower, user: @seller, email: "leaver@example.com")
    create(:active_follower, user: @seller, email: "stayer@example.com")
    post = create(:follower_post, :published, seller: @seller)
    unfollow_once_the_request_is_built(leaver)

    blast = send_blast(post)

    expect(requested_addresses).to eq(["stayer@example.com"])
    expect(SentPostEmail.where(post:).pluck(:email)).to eq(["stayer@example.com"])
    expect(blast.delivery_count).to eq(1)
    expect(blast.completed_at).to be_present
  end

  it "still sends an audience post to a buyer whose follow ended, as that buyer" do
    follower = create(:active_follower, user: @seller, email: "buyer-and-follower@example.com")
    purchase = create(:purchase, :from_seller, seller: @seller, email: follower.email)
    post = create(:audience_post, :published, seller: @seller)
    unfollow_before_the_provider_slice(follower)

    send_blast(post)

    expect(requested_addresses).to eq(["buyer-and-follower@example.com"])
    expect(@requests.sole[:custom_args].sole).to include("purchase_id" => purchase.id.to_s)
    expect(@requests.sole[:custom_args].sole).not_to have_key("follower_id")
    expect(SentPostEmail.where(post:).pluck(:email)).to eq(["buyer-and-follower@example.com"])
  end

  it "withholds an audience post's follower whose follow ended while the request was built, and nobody else" do
    leaver = create(:active_follower, user: @seller, email: "leaver@example.com")
    create(:purchase, :from_seller, seller: @seller, email: "buyer@example.com")
    create(:active_follower, user: @seller, email: "stayer@example.com")
    post = create(:audience_post, :published, seller: @seller)
    unfollow_once_the_request_is_built(leaver)

    blast = send_blast(post)

    expect(requested_addresses).to eq(["buyer@example.com", "stayer@example.com"])
    expect(SentPostEmail.where(post:).order(:email).pluck(:email)).to eq(["buyer@example.com", "stayer@example.com"])
    expect(blast.delivery_count).to eq(2)
  end

  describe "a follower whose stored address has capitals" do
    # Follows keep the address as typed; audience rows, and so the blast's recipients, are lowercased.
    before do
      @follower = create(:active_follower, user: @seller, email: "Mixed.Case@Example.com")
      create(:active_follower, user: @seller, email: "stayer@example.com")
      @post = create(:follower_post, :published, seller: @seller)
    end

    it "is still handed to SendGrid" do
      blast = send_blast(@post)

      expect(requested_addresses).to eq(["mixed.case@example.com", "stayer@example.com"])
      expect(SentPostEmail.where(post: @post).order(:email).pluck(:email)).to eq(["mixed.case@example.com", "stayer@example.com"])
      expect(blast.delivery_count).to eq(2)
    end

    it "is still handed to Resend" do
      Feature.activate(:use_resend_for_post_emails)
      Feature.activate_user(:force_resend_for_post_emails, @seller)

      send_blast(@post)

      expect(@requests.map { _1[:provider] }.uniq).to eq(["resend"])
      expect(requested_addresses).to eq(["mixed.case@example.com", "stayer@example.com"])
    ensure
      Feature.deactivate(:use_resend_for_post_emails)
    end

    it "is withheld once the follow moved to another address" do
      allow_any_instance_of(SendPostBlastEmailsJob).to receive(:send_provider_slice).and_wrap_original do |original, **kwargs|
        @follower.update!(email: "Moved.On@Example.com") if @follower.reload.email == "Mixed.Case@Example.com"
        original.call(**kwargs)
      end

      send_blast(@post)

      expect(requested_addresses).to eq(["stayer@example.com"])
      expect(SentPostEmail.where(post: @post).pluck(:email)).to eq(["stayer@example.com"])
    end
  end

  it "sends an audience post as the buyer or affiliate a member still is when their follow ends while the request is built" do
    product = create(:product, user: @seller)
    buyer = create(:active_follower, user: @seller, email: "buyer-follower@example.com")
    purchase = create(:purchase, :from_seller, seller: @seller, link: product, email: buyer.email)
    affiliate = create(:direct_affiliate, seller: @seller, send_posts: true)
    affiliate.products << product
    affiliate_follow = create(:active_follower, user: @seller, email: affiliate.affiliate_user.email)
    create(:active_follower, user: @seller, email: "stayer@example.com")
    post = create(:audience_post, :published, seller: @seller)
    built = 0
    allow_any_instance_of(PostSendgridApi).to receive(:build_mail).and_wrap_original do |original|
      request_body = original.call
      [buyer, affiliate_follow].each(&:mark_deleted!) if (built += 1) == 1
      request_body
    end
    settled = []
    allow_any_instance_of(SendPostBlastEmailsJob).to receive(:settle_pending_recipients).and_wrap_original do |original, skipped, owed|
      settled << [skipped.map(&:email), owed]
      original.call(skipped, owed)
    end

    blast = send_blast(post)

    expect(@requests.map { _1[:to].sort }).to eq([["stayer@example.com"], [affiliate_follow.email, buyer.email].sort])
    args_by_email = @requests.last[:to].zip(@requests.last[:custom_args]).to_h
    expect(args_by_email[buyer.email]).to include("purchase_id" => purchase.id.to_s)
    expect(args_by_email[affiliate_follow.email]).to include("affiliate_id" => affiliate.id.to_s)
    expect(args_by_email.values).to all(satisfy { !_1.key?("follower_id") })
    expect(SentPostEmail.where(post:).order(:email).pluck(:email)).to eq([affiliate_follow.email, buyer.email, "stayer@example.com"].sort)
    expect(settled).to eq([[[], 3]])
    expect(blast.delivery_count).to eq(3)
    expect(blast.completed_at).to be_present
  end

  it "sends a customer post to its buyers unchanged" do
    create(:purchase, :from_seller, seller: @seller, email: "buyer@example.com")
    create(:active_follower, user: @seller, email: "buyer@example.com").mark_deleted!
    post = create(:seller_post, :published, seller: @seller)

    send_blast(post)

    expect(requested_addresses).to eq(["buyer@example.com"])
    expect(@requests.sole[:custom_args].sole).to have_key("purchase_id")
  end

  # The audience filter loads only the roles that qualify for this post: a date filter, or the blast's own
  # started_at cutoff, can leave an affiliation on the member's row unloaded. Once the follow it was loaded for ends,
  # such a member has no role left to send them in.
  describe "an audience-post member whose only loaded role was the follow that ended" do
    before do
      @product = create(:product, user: @seller)
      @stayer = create(:active_follower, user: @seller, email: "stayer@example.com")
      @settled = []
      allow_any_instance_of(SendPostBlastEmailsJob).to receive(:settle_pending_recipients).and_wrap_original do |original, skipped, owed|
        @settled << [skipped.map(&:email).sort, owed]
        original.call(skipped, owed)
      end
    end

    def old_affiliation_for(email)
      affiliate_user = create(:affiliate_user, email:)
      create(:direct_affiliate, seller: @seller, affiliate_user:, send_posts: true, created_at: 30.days.ago).tap { _1.products << @product }
    end

    def dated_audience_post = create(:audience_post, :published, seller: @seller, created_after: 7.days.ago.to_date.iso8601)

    def expect_only_the_stayer_sent(post, member_email)
      expect(@requests.flat_map { _1[:to] }).to eq(["stayer@example.com"])
      expect(@requests.flat_map { _1[:unsubscribe_urls] }).not_to include("#")
      expect(SentPostEmail.where(post:).pluck(:email)).to eq(["stayer@example.com"])
      expect(@settled).to eq([[[member_email], 2]])
    end

    it "is not sent once the follow ends before the slice, though an affiliation outside the date filter remains" do
      follow = create(:active_follower, user: @seller, email: "dated-member@example.com")
      old_affiliation_for(follow.email)
      post = dated_audience_post
      unfollow_before_the_provider_slice(follow)

      blast = send_blast(post)

      expect_only_the_stayer_sent(post, follow.email)
      expect(blast.delivery_count).to eq(1)
      expect(blast.completed_at).to be_present
    end

    it "is not sent again once the follow ends while the request is built, though an affiliation outside the date filter remains" do
      follow = create(:active_follower, user: @seller, email: "dated-member@example.com")
      old_affiliation_for(follow.email)
      post = dated_audience_post
      built = 0
      allow_any_instance_of(PostSendgridApi).to receive(:build_mail).and_wrap_original do |original|
        request_body = original.call
        follow.mark_deleted! if (built += 1) == 1
        request_body
      end

      blast = send_blast(post)

      expect(built).to eq(1)
      expect_only_the_stayer_sent(post, follow.email)
      expect(blast.delivery_count).to eq(1)
    end

    it "is not sent through an affiliation added after the audience was loaded" do
      follow = create(:active_follower, user: @seller, email: "late-affiliate@example.com")
      post = create(:audience_post, :published, seller: @seller)
      allow_any_instance_of(SendPostBlastEmailsJob).to receive(:send_provider_slice).and_wrap_original do |original, **kwargs|
        unless follow.reload.deleted?
          create(:direct_affiliate, seller: @seller, affiliate_user: create(:affiliate_user, email: follow.email), send_posts: true).products << @product
          follow.mark_deleted!
        end
        original.call(**kwargs)
      end

      send_blast(post)

      expect_only_the_stayer_sent(post, follow.email)
    end

    it "is not sent as a purchase that opted out with the follow, though an affiliation outside the date filter remains" do
      follow = create(:active_follower, user: @seller, email: "buyer-member@example.com")
      purchase = create(:purchase, :from_seller, seller: @seller, link: @product, email: follow.email)
      old_affiliation_for(follow.email)
      post = dated_audience_post
      allow_any_instance_of(SendPostBlastEmailsJob).to receive(:send_provider_slice).and_wrap_original do |original, **kwargs|
        purchase.unsubscribe_buyer if purchase.reload.can_contact?
        original.call(**kwargs)
      end

      send_blast(post)

      expect(follow.reload).to be_deleted
      expect_only_the_stayer_sent(post, follow.email)
    end

    it "is sent as the affiliate it still is when the purchase and the follow opt out but a qualifying affiliation remains" do
      follow = create(:active_follower, user: @seller, email: "affiliate-member@example.com")
      purchase = create(:purchase, :from_seller, seller: @seller, link: @product, email: follow.email)
      affiliate = create(:direct_affiliate, seller: @seller, affiliate_user: create(:affiliate_user, email: follow.email), send_posts: true)
      affiliate.products << @product
      post = dated_audience_post
      allow_any_instance_of(SendPostBlastEmailsJob).to receive(:send_provider_slice).and_wrap_original do |original, **kwargs|
        purchase.unsubscribe_buyer if purchase.reload.can_contact?
        original.call(**kwargs)
      end

      send_blast(post)

      member = @requests.flat_map { |request| request[:to].zip(request[:custom_args], request[:unsubscribe_urls]) }.find { _1[0] == follow.email }
      expect(member[1]).to include("affiliate_id" => affiliate.id.to_s)
      expect(member[1].keys).not_to include("purchase_id", "follower_id")
      expect(member[2]).to eq(unsubscribe_posts_affiliate_url(affiliate.external_id))
      expect(SentPostEmail.where(post:).order(:email).pluck(:email)).to eq([follow.email, "stayer@example.com"])
      expect(@settled).to eq([[[], 2]])
    end

    it "is sent as the buyer it still is when only the follow ends before the slice, under the date filter" do
      follow = create(:active_follower, user: @seller, email: "dated-buyer@example.com")
      purchase = create(:purchase, :from_seller, seller: @seller, link: @product, email: follow.email)
      post = dated_audience_post
      unfollow_before_the_provider_slice(follow)

      send_blast(post)

      member = @requests.flat_map { |request| request[:to].zip(request[:custom_args], request[:unsubscribe_urls]) }.find { _1[0] == follow.email }
      expect(member[1]).to include("purchase_id" => purchase.id.to_s)
      expect(member[1].keys).not_to include("follower_id", "affiliate_id")
      expect(member[2]).to match(%r{/purchases/[^/]+/unsubscribe\z})
      expect(@settled).to eq([[[], 2]])
    end
  end

  describe "a follower workflow post" do
    before do
      @installment = create(:follower_installment, seller: @seller, workflow: create(:workflow, seller: @seller, link: nil, workflow_type: Workflow::FOLLOWER_TYPE))
      @follower = create(:active_follower, user: @seller, email: "workflow-follower@example.com")
      allow(Rails.env).to receive(:test?).and_return(false)
    end

    it "sends nothing and keeps no claim when the follow ends after the worker checked it" do
      allow(PostEmailApi).to receive(:process).and_wrap_original do |original, **kwargs|
        @follower.mark_deleted!
        original.call(**kwargs)
      end

      @installment.send_installment_from_workflow_for_follower(@follower.id)

      expect(@requests).to be_empty
      expect(SentPostEmail.where(post: @installment)).to be_empty
    end

    it "sends to a follow that is still live" do
      @installment.send_installment_from_workflow_for_follower(@follower.id)

      expect(requested_addresses).to eq(["workflow-follower@example.com"])
      expect(SentPostEmail.where(post: @installment).pluck(:email)).to eq(["workflow-follower@example.com"])
    end
  end
end
