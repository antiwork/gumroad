# frozen_string_literal: true

require "spec_helper"

describe SendPostBlastEmailsJob, :freeze_time do
  include Rails.application.routes.url_helpers, ActionView::Helpers::SanitizeHelper
  _routes.default_url_options = Rails.application.config.action_mailer.default_url_options

  before do
    @seller = create(:named_user)

    # Since secure_external_id changes on each call, we need to mock it to get a consistent value
    allow_any_instance_of(Purchase).to receive(:secure_external_id) do |purchase, scope:|
      "sample-secure-id-#{scope}-#{purchase.id}"
    end
  end

  let(:basic_post_with_audience) do
    post = create(:audience_post, :published, seller: @seller)
    create(:active_follower, user: @seller)
    post
  end

  describe "#perform" do
    it "ignores deleted posts" do
      basic_post_with_audience.mark_deleted!
      blast = create(:blast, :just_requested, post: basic_post_with_audience)
      described_class.new.perform(blast.id)

      expect_sent_count 0
      expect(blast.reload.started_at).to be_blank
      expect(blast.completed_at).to be_blank
    end

    it "ignores unpublished posts" do
      basic_post_with_audience.update!(published_at: nil)
      blast = create(:blast, :just_requested, post: basic_post_with_audience)
      described_class.new.perform(blast.id)

      expect_sent_count 0
      expect(blast.reload.started_at).to be_blank
      expect(blast.completed_at).to be_blank
    end

    it "ignores posts where send_emails is false" do
      basic_post_with_audience.update!(published_at: nil)
      blast = create(:blast, :just_requested, post: basic_post_with_audience)
      described_class.new.perform(blast.id)

      expect_sent_count 0
      expect(blast.reload.started_at).to be_blank
      expect(blast.completed_at).to be_blank
    end

    it "ignores completed blasts" do
      blast = create(:blast, post: basic_post_with_audience, completed_at: Time.current)
      described_class.new.perform(blast.id)

      expect_sent_count 0
    end

    it "records when blast started processing" do
      blast = create(:blast, :just_requested, post: basic_post_with_audience)
      described_class.new.perform(blast.id)

      expect(blast.reload.started_at).to be_present
    end

    it "does not email the same recipients twice, when the post has been published twice" do
      blast = create(:blast, :just_requested, post: basic_post_with_audience)
      described_class.new.perform(blast.id)

      expect_sent_count 1
      recipient_email = basic_post_with_audience.seller.followers.first.email
      expect(PostSendgridApi.mails.keys).to eq([recipient_email])

      PostSendgridApi.mails.clear
      blast_2 = create(:blast, :just_requested, post: basic_post_with_audience)
      described_class.new.perform(blast_2.id)
      expect_sent_count 0
    end

    context "for different post types" do
      before do
        @products = []
        @products << create(:product, user: @seller, name: "Product one")
        @products << create(:product, user: @seller, name: "Product two")
        category = create(:variant_category, link: @products[0])
        @variants = create_list(:variant, 2, variant_category: category)
        @products << create(:product, :is_subscription, user: @seller, name: "Product three")

        @sales = []
        @sales << create(:purchase, link: @products[0])
        @sales << create(:purchase, link: @products[1], email: @sales[0].email)
        @sales << create(:purchase, link: @products[0])
        @sales << create(:purchase, link: @products[1], variant_attributes: [@variants[0]])
        @sales << create(:purchase, link: @products[1], variant_attributes: [@variants[1]])
        @sales << create(:membership_purchase, link: @products[2])

        @followers = []
        @followers << create(:active_follower, user: @seller)
        @followers << create(:active_follower, user: @seller, email: @sales[0].email)

        @affiliates = []
        @affiliates << create(:direct_affiliate, seller: @seller, send_posts: true)
        @affiliates[0].products << @products[0]
        @affiliates[0].products << @products[1]

        # Basic check for working recipient filtering.
        # The details of it are tested in the Installment model specs.
        create(:deleted_follower, user: @seller)
        create(:purchase, link: @products[0], can_contact: false)
        create(:direct_affiliate, seller: @seller, send_posts: false).products << @products[0]
        create(:membership_purchase, email: @sales[5].email, link: @products[2], subscription: @sales[5].subscription, is_original_subscription_purchase: false)
      end

      it "when product_type? is true, it sends the expected emails" do
        post = create(:product_post, :published, link: @products[0], bought_products: [@products[0].unique_permalink])
        blast = create(:blast, :just_requested, post:)
        expect do
          described_class.new.perform(blast.id)
        end.to change { UrlRedirect.count }.by(2)

        expect_sent_count 2

        expect_sent_email @sales[0].email, content_match: [
          /because you've purchased.*#{post.purchase_url_redirect(@sales[0]).download_page_url}.*#{@products[0].name}/,
          /#{unsubscribe_purchase_url(@sales[0].secure_external_id(scope: "unsubscribe"))}.*Unsubscribe/
        ]
        expect_sent_email @sales[2].email, content_match: [
          /because you've purchased.*#{post.purchase_url_redirect(@sales[2]).download_page_url}.*#{@products[0].name}/,
          /#{unsubscribe_purchase_url(@sales[2].secure_external_id(scope: "unsubscribe"))}.*Unsubscribe/
        ]
      end

      it "when product_type? is true and not_bought_products filter is present it sends the expected emails" do
        post = create(:product_post, :published, link: @products[0], not_bought_products: [@products[0].unique_permalink])
        blast = create(:blast, :just_requested, post:)
        expect do
          described_class.new.perform(blast.id)
        end.to change { UrlRedirect.count }.by(3)

        expect_sent_count 3

        expect_sent_email @sales[3].email, content_match: [
          /because you've purchased.*#{post.purchase_url_redirect(@sales[3]).download_page_url}.*#{@products[1].name}/,
          /#{unsubscribe_purchase_url(@sales[3].secure_external_id(scope: "unsubscribe"))}.*Unsubscribe/
        ]
        expect_sent_email @sales[4].email, content_match: [
          /because you've purchased.*#{post.purchase_url_redirect(@sales[4]).download_page_url}.*#{@products[1].name}/,
          /#{unsubscribe_purchase_url(@sales[4].secure_external_id(scope: "unsubscribe"))}.*Unsubscribe/
        ]
        expect_sent_email @sales[5].email, content_match: [
          /because you've purchased.*#{post.purchase_url_redirect(@sales[5]).download_page_url}.*#{@products[2].name}/,
          /#{unsubscribe_purchase_url(@sales[5].secure_external_id(scope: "unsubscribe"))}.*Unsubscribe/
        ]
      end

      it "when variant_type? is true, it sends the expected emails" do
        post = create(:variant_post, :published, link: @products[1], base_variant: @variants[0], bought_variants: [@variants[0].external_id])
        blast = create(:blast, :just_requested, post:)

        expect do
          described_class.new.perform(blast.id)
        end.to change { UrlRedirect.count }.by(1)

        expect_sent_count 1
        expect_sent_email @sales[3].email, content_match: [
          /because you've purchased.*#{post.purchase_url_redirect(@sales[3]).download_page_url}.*#{@products[1].name}/,
          /#{unsubscribe_purchase_url(@sales[3].secure_external_id(scope: "unsubscribe"))}.*Unsubscribe/
        ]
      end

      it "when seller_type? is true, it sends the expected emails" do
        post = create(:seller_post, :published, seller: @seller)
        blast = create(:blast, :just_requested, post:)
        described_class.new.perform(blast.id)

        expect_sent_count 5
        [1, 2, 3, 4, 5].each do |sale_index|
          expect_sent_email @sales[sale_index].email, content_match: [
            /because you've purchased a product from #{@seller.name}/,
            /#{unsubscribe_purchase_url(@sales[sale_index].secure_external_id(scope: "unsubscribe"))}.*Unsubscribe/
          ]
        end
      end

      it "when follower_type? is true, it sends the expected emails" do
        post = create(:follower_post, :published, seller: @seller)
        blast = create(:blast, :just_requested, post:)
        described_class.new.perform(blast.id)

        expect_sent_count 2
        @followers.each do |follower|
          expect_sent_email follower.email, content_match: [
            /#{cancel_follow_url(follower.external_id)}.*Unsubscribe/
          ]
        end
      end

      it "when affiliate_type? is true, it sends the expected emails" do
        post = create(:affiliate_post, :published, seller: @seller, affiliate_products: [@products[0].unique_permalink])
        blast = create(:blast, :just_requested, post:)
        described_class.new.perform(blast.id)

        expect_sent_count 1
        expect_sent_email @affiliates[0].affiliate_user.email, content_match: [
          /#{unsubscribe_posts_affiliate_url(@affiliates[0].external_id)}.*Unsubscribe/
        ]
      end

      it "when audience_type? is true, it sends the expected emails" do
        post = create(:audience_post, :published, seller: @seller)
        blast = create(:blast, :just_requested, post:)
        described_class.new.perform(blast.id)

        expect_sent_count 7
        [0, 1].each do |follower_index|
          expect_sent_email @followers[follower_index].email, content_match: [
            /#{cancel_follow_url(@followers[follower_index].external_id)}.*Unsubscribe/
          ]
        end
        expect_sent_email @affiliates[0].affiliate_user.email, content_match: [
          /#{unsubscribe_posts_affiliate_url(@affiliates[0].external_id)}.*Unsubscribe/
        ]
        [2, 3, 4, 5].each do |sale_index|
          expect_sent_email @sales[sale_index].email, content_match: [
            /#{unsubscribe_purchase_url(@sales[sale_index].secure_external_id(scope: "unsubscribe"))}.*Unsubscribe/
          ]
        end
      end
    end

    describe "Attachments and UrlRedirect" do
      before do
        @followers = create_list(:active_follower, 2, user: @seller)
        @purchases = []
        @purchases << create(:purchase, :from_seller, seller: @seller)
        @purchases << create(:membership_purchase, :from_seller, seller: @seller)
        @post = create(:audience_post, :published, seller: @seller)
        @blast = create(:blast, :just_requested, post: @post)
      end

      it "creates the UrlRedirect records and adds a download button to the email" do
        @post.product_files << create(:product_file)

        expect do
          described_class.new.perform(@blast.id)
        end.to change { UrlRedirect.count }.by(3)

        expect_sent_count 4

        url_redirect_for_followers = UrlRedirect.find_by!(installment_id: @post.id, purchase_id: nil)
        @followers.each do |follower|
          expect_sent_email follower.email, content_match: [
            /#{url_redirect_for_followers.download_page_url}.*View content/,
          ]
        end

        @purchases.each do |purchase|
          expect_sent_email purchase.email, content_match: [
            /#{UrlRedirect.find_by!(installment_id: @post.id, purchase_id: purchase.id, subscription_id: purchase.subscription_id).download_page_url}.*View content/,
          ]
        end
      end

      it "does not create the UrlRedirect records if the post has no attachments" do
        expect do
          described_class.new.perform(@blast.id)
        end.not_to change { UrlRedirect.count }

        expect_sent_count 4
        PostSendgridApi.mails.each do |email, _|
          expect_sent_email email, content_not_match: [
            /View content/,
          ]
        end
      end
    end

    context "recipients slice size" do
      before do
        stub_const("PostSendgridApi::MAX_RECIPIENTS", 10)
        @blast = create(:blast, :just_requested, post: basic_post_with_audience)
        create_list(:active_follower, 10, user: @seller) # there are now 11 followers
        @expected_base_args = { post: @blast.post, blast: @blast, cache: anything }
      end

      it "is equal to PostSendgridApi::MAX_RECIPIENTS by default" do
        expect(PostSendgridApi).to receive(:process).with(recipients: satisfy { _1.size == 10 }, **@expected_base_args).once.and_call_original
        expect(PostSendgridApi).to receive(:process).with(recipients: satisfy { _1.size == 1 }, **@expected_base_args).once.and_call_original

        described_class.new.perform(@blast.id)

        expect_sent_count 11
      end

      it "can be controlled by redis key" do
        $redis.set(RedisKey.blast_recipients_slice_size, 4)

        expect(PostSendgridApi).to receive(:process).with(recipients: satisfy { _1.size == 4 }, **@expected_base_args).twice.and_call_original
        expect(PostSendgridApi).to receive(:process).with(recipients: satisfy { _1.size == 3 }, **@expected_base_args).once.and_call_original

        described_class.new.perform(@blast.id)

        expect_sent_count 11
      end
    end
  end

  describe "error handling" do
    it "deletes sent_post_emails records if PostEmailApi.process raises an error" do
      # Setup post and blast
      post = create(:audience_post, :published, seller: @seller)
      create(:active_follower, user: @seller)
      blast = create(:blast, :just_requested, post: post)

      # Mock PostEmailApi to raise an error
      expect(PostEmailApi).to receive(:process).and_raise(StandardError.new("API failure"))

      # Run the job and expect it to raise the error
      expect do
        described_class.new.perform(blast.id)
      end.to raise_error(StandardError, "API failure")

      # Verify that no SentPostEmail records exist
      expect(SentPostEmail.where(post: post).count).to eq(0)
    end
  end

  def expect_sent_count(count)
    expect(PostSendgridApi.mails.size).to eq(count)
  end

  def expect_sent_email(email, content_match: nil, content_not_match: nil)
    expect(PostSendgridApi.mails[email]).to be_present
    Array.wrap(content_match).each { expect(PostSendgridApi.mails[email][:content]).to match(_1) }
    Array.wrap(content_not_match).each { expect(PostSendgridApi.mails[email][:content]).not_to match(_1) }
  end
end
