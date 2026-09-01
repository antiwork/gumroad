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

  # Asserted on the options rather than on behaviour because SidekiqUniqueJobs is disabled outright
  # in test (`config.enabled = !Rails.env.test?`), so a re-enqueue succeeds here either way. A
  # stranded digest silently drops every later `perform_async` for the blast, which is what made
  # resuming a hard-killed blast a no-op (gumroad-private#1816).
  it "declares no unique lock, so a stranded digest cannot suppress a resume" do
    expect(described_class.get_sidekiq_options).not_to have_key("lock")
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

    it "records how many recipients it still owes, and clears the count when it finishes" do
      blast = create(:blast, :just_requested, post: basic_post_with_audience)
      pending_key = RedisKey.blast_pending_recipients(blast.id)

      described_class.new.perform(blast.id)

      expect_sent_count 1
      expect(blast.reload.completed_at).to be_present
      expect($redis.exists?(pending_key)).to be(false)
    end

    it "leaves the owed count positive through the stalled-blast scan window when the send dies before the provider call" do
      blast = create(:blast, :just_requested, post: basic_post_with_audience)
      pending_key = RedisKey.blast_pending_recipients(blast.id)
      expect(PostSendgridApi).to receive(:process).and_raise(StandardError.new("API failure"))

      expect { described_class.new.perform(blast.id) }.to raise_error(StandardError, "API failure")

      expect($redis.get(pending_key).to_i).to eq(1)
      expect($redis.ttl(RedisKey.blast_audience_snapshot(blast.id))).to be_between(
        13.days.to_i,
        AlertOnStalledPostEmailBlastsJob::LOOKBACK.to_i
      ).inclusive
      expect($redis.ttl(pending_key)).to be_between(13.days.to_i, AlertOnStalledPostEmailBlastsJob::LOOKBACK.to_i).inclusive
      expect(described_class.fully_delivered?(blast.reload)).to be(false)
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
        @post.product_files << create(:product_file, link: nil, installment: @post)

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

  describe "resending to non-openers" do
    let(:product) { create(:product, user: @seller, name: "Product one") }
    let(:post) { create(:product_post, :published, seller: @seller, link: product, bought_products: [product.unique_permalink]) }
    let!(:opened_sale) { create(:purchase, link: product, seller: @seller) }
    let!(:delivered_sale) { create(:purchase, link: product, seller: @seller) }
    let!(:sent_sale) { create(:purchase, link: product, seller: @seller) }

    before do
      # Simulate the original blast: every recipient was emailed (recorded in sent_post_emails and
      # email_infos), one of them opened it.
      [opened_sale, delivered_sale, sent_sale].each do |sale|
        SentPostEmail.create!(post:, email: sale.email)
      end
      create(:creator_contacting_customers_email_info_opened, installment: post, purchase: opened_sale)
      create(:creator_contacting_customers_email_info_delivered, installment: post, purchase: delivered_sale)
      create(:creator_contacting_customers_email_info_sent, installment: post, purchase: sent_sale)
    end

    it "sends only to original recipients who have not opened the email" do
      blast = create(:blast, :just_requested, post:, recipient_filter: "unopened")
      described_class.new.perform(blast.id)

      expect_sent_count 2
      expect(PostSendgridApi.mails[delivered_sale.email]).to be_present
      expect(PostSendgridApi.mails[sent_sale.email]).to be_present
      expect(PostSendgridApi.mails[opened_sale.email]).to be_blank
      expect(blast.reload.completed_at).to be_present
    end

    it "bypasses the already-emailed guard so it can re-send to people in sent_post_emails" do
      expect(SentPostEmail.where(post:).count).to eq(3)

      blast = create(:blast, :just_requested, post:, recipient_filter: "unopened")
      described_class.new.perform(blast.id)

      # All recipients were already in sent_post_emails, yet the resend still goes out to non-openers.
      expect_sent_count 2
      # The resend does not add new sent_post_emails records.
      expect(SentPostEmail.where(post:).count).to eq(3)
    end

    it "sends nothing when everyone who was emailed has already opened" do
      create(:creator_contacting_customers_email_info_opened, installment: post, purchase: delivered_sale)
      create(:creator_contacting_customers_email_info_opened, installment: post, purchase: sent_sale)

      blast = create(:blast, :just_requested, post:, recipient_filter: "unopened")
      described_class.new.perform(blast.id)

      expect_sent_count 0
      expect(blast.reload.completed_at).to be_present
    end

    it "does not delete sent_post_emails when a resend raises an error" do
      blast = create(:blast, :just_requested, post:, recipient_filter: "unopened")
      allow(PostEmailApi).to receive(:provider_for).and_return(MailerInfo::EMAIL_PROVIDER_SENDGRID)
      expect(PostSendgridApi).to receive(:process).and_raise(StandardError.new("API failure"))

      expect do
        described_class.new.perform(blast.id)
      end.to raise_error(StandardError, "API failure")

      expect(SentPostEmail.where(post:).count).to eq(3)
    end

    it "resolves the unopened-recipient emails under the raised statement execution cap" do
      blast = create(:blast, :just_requested, post:, recipient_filter: "unopened")

      # Once for the audience load, once for the unopened-recipient email resolution.
      expect(WithMaxExecutionTime).to receive(:timeout_queries).with(seconds: 1.hour.to_i).twice.and_call_original
      described_class.new.perform(blast.id)

      expect_sent_count 2
      expect(blast.reload.completed_at).to be_present
    end

    describe "non-opener checkpoint" do
      let(:blast) { create(:blast, :just_requested, post:, recipient_filter: "unopened") }
      let(:checkpoint_key) { RedisKey.blast_non_opener_emails(blast.id) }

      after { $redis.del(checkpoint_key, "#{checkpoint_key}:tmp") }

      it "checkpoints the resolved non-opener emails while the blast is running and clears them on completion" do
        checkpoint_during_run = nil
        allow(PostEmailApi).to receive(:provider_for).and_return(MailerInfo::EMAIL_PROVIDER_SENDGRID)
        allow(PostSendgridApi).to receive(:process) do |**_kwargs|
          checkpoint_during_run = $redis.smembers(checkpoint_key)
        end

        described_class.new.perform(blast.id)

        expect(checkpoint_during_run).to match_array([delivered_sale.email, sent_sale.email])
        expect($redis.exists?(checkpoint_key)).to eq(false)
        expect(blast.reload.completed_at).to be_present
      end

      it "reuses the checkpoint on a later attempt instead of recomputing it" do
        $redis.sadd(checkpoint_key, [delivered_sale.email])

        expect_any_instance_of(Installment).not_to receive(:unopened_recipient_emails)
        described_class.new.perform(blast.id)

        expect_sent_count 1
        expect(PostSendgridApi.mails[delivered_sale.email]).to be_present
        expect(PostSendgridApi.mails[sent_sale.email]).to be_blank
      end

      it "renews a reused checkpoint when the resumed send fails" do
        $redis.sadd(checkpoint_key, [delivered_sale.email])
        $redis.expire(checkpoint_key, 5.minutes.to_i)
        allow(PostEmailApi).to receive(:provider_for).and_return(MailerInfo::EMAIL_PROVIDER_SENDGRID)
        expect(PostSendgridApi).to receive(:process).and_raise(StandardError.new("API failure"))

        expect do
          described_class.new.perform(blast.id)
        end.to raise_error(StandardError, "API failure")

        expect($redis.ttl(checkpoint_key)).to be_between(13.days.to_i, AlertOnStalledPostEmailBlastsJob::LOOKBACK.to_i).inclusive
      end

      it "keeps the checkpoint when the send fails so the next attempt can reuse it" do
        allow(PostEmailApi).to receive(:provider_for).and_return(MailerInfo::EMAIL_PROVIDER_SENDGRID)
        expect(PostSendgridApi).to receive(:process).and_raise(StandardError.new("API failure"))

        expect do
          described_class.new.perform(blast.id)
        end.to raise_error(StandardError, "API failure")

        expect($redis.smembers(checkpoint_key)).to match_array([delivered_sale.email, sent_sale.email])
      end

      it "ignores a partially written checkpoint left behind by a killed attempt" do
        # A half-finished write lives only at the :tmp key. The real key must stay absent
        # so the next attempt recomputes rather than sending to a fraction of the
        # non-openers.
        $redis.sadd("#{checkpoint_key}:tmp", ["stale@example.com"])

        described_class.new.perform(blast.id)

        expect_sent_count 2
        expect($redis.exists?("#{checkpoint_key}:tmp")).to eq(false)
      end
    end
  end

  describe "audience load statement timeout" do
    it "loads the audience with a raised statement execution cap of one hour by default" do
      blast = create(:blast, :just_requested, post: basic_post_with_audience)

      expect(WithMaxExecutionTime).to receive(:timeout_queries).with(seconds: 1.hour.to_i).and_call_original
      described_class.new.perform(blast.id)

      expect_sent_count 1
      expect(blast.reload.completed_at).to be_present
    end

    it "honors the Redis override for the statement execution cap" do
      $redis.set(RedisKey.audience_member_load_max_execution_time_seconds, 2.hours.to_i)
      blast = create(:blast, :just_requested, post: basic_post_with_audience)

      expect(WithMaxExecutionTime).to receive(:timeout_queries).with(seconds: 2.hours.to_i).and_call_original
      described_class.new.perform(blast.id)

      expect_sent_count 1
    ensure
      $redis.del(RedisKey.audience_member_load_max_execution_time_seconds)
    end
  end

  describe "audience snapshot for retry resume" do
    it "snapshots the audience member ids in Redis and clears the snapshot on completion" do
      post = basic_post_with_audience
      blast = create(:blast, :just_requested, post:)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)

      snapshot_during_run = nil
      allow(PostEmailApi).to receive(:provider_for).and_return(MailerInfo::EMAIL_PROVIDER_SENDGRID)
      allow(PostSendgridApi).to receive(:process) do |**_kwargs|
        snapshot_during_run = $redis.lrange(snapshot_key, 0, -1)
      end

      described_class.new.perform(blast.id)

      expected_ids = AudienceMember.where(seller_id: post.seller_id).pluck(:id)
      expect(snapshot_during_run.map(&:to_i)).to match_array(expected_ids)
      expect($redis.exists?(snapshot_key)).to eq(false)
      expect(blast.reload.completed_at).to be_present
    end

    it "does not rebuild the live audience when a late resume finds no snapshot" do
      post = basic_post_with_audience
      blast = create(:blast, :just_requested, post:)
      blast.update!(started_at: 2.days.ago)
      create(:active_follower, user: @seller)

      unrestricted = false
      allow(AudienceMember).to receive(:filter).and_wrap_original do |original, **kwargs|
        unrestricted = true unless kwargs.key?(:ids)
        original.call(**kwargs)
      end

      expect do
        described_class.new.perform(blast.id)
      end.to raise_error(RuntimeError, /missing audience snapshot for blast #{blast.id}/)

      expect(unrestricted).to eq(false)
      expect_sent_count 0
      expect(blast.reload.completed_at).to be_nil
    end

    it "rebuilds the audience when a resume finds no snapshot inside the grace window" do
      post = basic_post_with_audience
      blast = create(:blast, :just_requested, post:)
      blast.update!(started_at: 1.hour.ago)
      create(:active_follower, user: @seller)

      unrestricted = false
      allow(AudienceMember).to receive(:filter).and_wrap_original do |original, **kwargs|
        unrestricted = true unless kwargs.key?(:ids)
        original.call(**kwargs)
      end

      described_class.new.perform(blast.id)

      expect(unrestricted).to eq(true)
      expect_sent_count 2
      expect(blast.reload.completed_at).to be_present
    end

    it "refuses a resume with no snapshot inside the grace window when recipients are still pending" do
      post = basic_post_with_audience
      blast = create(:blast, :just_requested, post:)
      blast.update!(started_at: 1.hour.ago)
      pending_key = RedisKey.blast_pending_recipients(blast.id)
      # An earlier attempt already published its recipient count, so it had a snapshot:
      # the missing one is lost Redis state, not a first-run crash.
      $redis.set(pending_key, 1)
      create(:active_follower, user: @seller)

      unrestricted = false
      allow(AudienceMember).to receive(:filter).and_wrap_original do |original, **kwargs|
        unrestricted = true unless kwargs.key?(:ids)
        original.call(**kwargs)
      end

      expect do
        described_class.new.perform(blast.id)
      end.to raise_error(RuntimeError, /missing audience snapshot for blast #{blast.id}/)

      expect(unrestricted).to eq(false)
      expect_sent_count 0
      expect(blast.reload.completed_at).to be_nil
    ensure
      $redis.del(pending_key) if pending_key
    end

    it "completes without a live rebuild when a resume with no snapshot owes no more recipients" do
      post = basic_post_with_audience
      blast = create(:blast, :just_requested, post:)
      blast.update!(started_at: 1.hour.ago)
      pending_key = RedisKey.blast_pending_recipients(blast.id)
      # Everything was already handed to the ESP; this resume exists only to stamp
      # `completed_at`, so a missing snapshot must neither stall it nor pull in the
      # follower who joined after the original send.
      $redis.set(pending_key, 0)
      create(:active_follower, user: @seller)

      unrestricted = false
      allow(AudienceMember).to receive(:filter).and_wrap_original do |original, **kwargs|
        unrestricted = true unless kwargs.key?(:ids)
        original.call(**kwargs)
      end

      described_class.new.perform(blast.id)

      expect(unrestricted).to eq(false)
      expect_sent_count 0
      expect(blast.reload.completed_at).to be_present
    ensure
      $redis.del(pending_key) if pending_key
    end

    it "resumes from the snapshot on retry using only an id-restricted filter" do
      post = basic_post_with_audience
      blast = create(:blast, :just_requested, post:)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)
      snapshotted_ids = AudienceMember.where(seller_id: post.seller_id).pluck(:id)
      $redis.rpush(snapshot_key, snapshotted_ids)

      # The retry must never run the unrestricted filter (that's the expensive query the
      # snapshot exists to avoid) — every call must be bounded to the snapshotted ids.
      expect(AudienceMember).to receive(:filter).with(hash_including(ids: snapshotted_ids)).and_call_original
      described_class.new.perform(blast.id)

      expect_sent_count 1
      expect(blast.reload.completed_at).to be_present
      expect($redis.exists?(snapshot_key)).to eq(false)
    ensure
      $redis.del(snapshot_key)
    end

    it "renews a reused audience snapshot when the resumed send fails" do
      post = basic_post_with_audience
      blast = create(:blast, :just_requested, post:)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)
      $redis.rpush(snapshot_key, AudienceMember.where(seller_id: post.seller_id).pluck(:id))
      $redis.expire(snapshot_key, 5.minutes.to_i)
      allow(PostEmailApi).to receive(:provider_for).and_return(MailerInfo::EMAIL_PROVIDER_SENDGRID)
      expect(PostSendgridApi).to receive(:process).and_raise(StandardError.new("API failure"))

      expect do
        described_class.new.perform(blast.id)
      end.to raise_error(StandardError, "API failure")

      expect($redis.ttl(snapshot_key)).to be_between(13.days.to_i, AlertOnStalledPostEmailBlastsJob::LOOKBACK.to_i).inclusive
      expect($redis.ttl(RedisKey.blast_pending_recipients(blast.id))).to be_between(13.days.to_i, AlertOnStalledPostEmailBlastsJob::LOOKBACK.to_i).inclusive
    ensure
      $redis.del(snapshot_key, RedisKey.blast_pending_recipients(blast.id)) if snapshot_key
    end

    it "revalidates the snapshot under the raised statement execution cap" do
      post = basic_post_with_audience
      blast = create(:blast, :just_requested, post:)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)
      $redis.rpush(snapshot_key, AudienceMember.where(seller_id: post.seller_id).pluck(:id))

      # The id-restricted revalidation still joins large tables per slice and can exceed
      # the database's default statement cap on huge audiences — the retry path must use
      # the same raised cap as the fresh audience load.
      expect(WithMaxExecutionTime).to receive(:timeout_queries).with(seconds: 1.hour.to_i).and_call_original
      described_class.new.perform(blast.id)

      expect_sent_count 1
      expect(blast.reload.completed_at).to be_present
    ensure
      $redis.del(snapshot_key)
    end

    it "revalidates the snapshot in slices small enough to stay on the primary key" do
      post = basic_post_with_audience
      create(:active_follower, user: @seller)
      create(:active_follower, user: @seller)
      blast = create(:blast, :just_requested, post:)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)
      snapshotted_ids = AudienceMember.where(seller_id: post.seller_id).pluck(:id)
      expect(snapshotted_ids.size).to be >= 3
      $redis.rpush(snapshot_key, snapshotted_ids)

      # A big `IN (...)` list makes MySQL abandon the primary key and scan the whole
      # table, so the revalidation must never hand the filter more ids than the slice
      # size — regardless of how large the audience is.
      stub_const("#{described_class}::REVALIDATION_SLICE_SIZE", 2)
      slice_sizes = []
      allow(AudienceMember).to receive(:filter).and_wrap_original do |original, **kwargs|
        slice_sizes << kwargs[:ids].size
        original.call(**kwargs)
      end

      described_class.new.perform(blast.id)

      expect(slice_sizes.size).to eq((snapshotted_ids.size / 2.0).ceil)
      expect(slice_sizes).to all(be <= 2)
      expect(slice_sizes.sum).to eq(snapshotted_ids.size)
      expect(blast.reload.completed_at).to be_present
    ensure
      $redis.del(snapshot_key)
    end

    it "drops snapshotted members who have since left the audience" do
      post = basic_post_with_audience
      blast = create(:blast, :just_requested, post:)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)
      snapshotted_ids = AudienceMember.where(seller_id: post.seller_id).pluck(:id)
      departed_id = snapshotted_ids.max + 1_000
      $redis.rpush(snapshot_key, snapshotted_ids + [departed_id])

      described_class.new.perform(blast.id)

      expect_sent_count 1
      expect(blast.reload.completed_at).to be_present
    ensure
      $redis.del(snapshot_key)
    end

    it "drops snapshotted members who lost the targeted role but kept their audience row" do
      # A follower who is ALSO a customer keeps their audience_members row when they
      # unsubscribe from follower updates — only the follower entry leaves the row's
      # details. A follower-targeted retry must not email them from the stale snapshot.
      post = create(:follower_post, :published, seller: @seller)
      follower = create(:active_follower, user: @seller)
      # Give the follower a purchase too, so their audience_members row SURVIVES the
      # follower opt-out below — the mixed-role case this test is about.
      create(:free_purchase, link: create(:product, user: @seller), seller: @seller, email: follower.email)
      blast = create(:blast, :just_requested, post:)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)
      snapshotted_ids = AudienceMember.filter(seller_id: post.seller_id, params: post.audience_members_filter_params).pluck(:id)
      expect(snapshotted_ids).not_to be_empty
      $redis.rpush(snapshot_key, snapshotted_ids)

      # Simulate the mixed-role opt-out between attempts: unsubscribing removes the
      # follower entry from the member's details, but the row survives because they're
      # still a customer.
      follower.mark_deleted!
      expect(AudienceMember.find_by(email: follower.email, seller: @seller)).to be_present

      described_class.new.perform(blast.id)

      expect(PostSendgridApi.mails[follower.email]).to be_blank
      expect_sent_count 0
      expect(blast.reload.completed_at).to be_present
    ensure
      $redis.del(snapshot_key)
    end

    it "drops snapshotted members whose qualifying purchase left the audience even though their row survives" do
      # A buyer who is ALSO a follower: refunding the purchase removes it from the
      # member's details but keeps the audience_members row (they're still a follower).
      # A retried product blast must not email them from the stale snapshot.
      product = create(:product, user: @seller)
      purchase = create(:free_purchase, link: product, seller: @seller)
      create(:active_follower, user: @seller, email: purchase.email)
      post = create(:product_post, :published, seller: @seller, link: product, bought_products: [product.unique_permalink])
      blast = create(:blast, :just_requested, post:)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)
      snapshotted_ids = AudienceMember.filter(seller_id: post.seller_id, params: post.audience_members_filter_params).pluck(:id)
      expect(snapshotted_ids).not_to be_empty
      $redis.rpush(snapshot_key, snapshotted_ids)

      # Simulate the purchase leaving the audience (refund) between snapshot and retry.
      purchase.update_columns(stripe_refunded: true)
      purchase.rebuild_audience_member_details
      expect(AudienceMember.find_by(email: purchase.email, seller: @seller)).to be_present

      described_class.new.perform(blast.id)

      expect(PostSendgridApi.mails[purchase.email]).to be_blank
      expect(blast.reload.completed_at).to be_present
    ensure
      $redis.del(snapshot_key) if snapshot_key
    end

    it "ignores a leftover partial write at the temporary key and re-runs the filter" do
      # If a worker dies partway through writing the snapshot, the half-written list
      # lives only at the :tmp key — the real key must stay absent so a retry re-runs
      # the full audience filter instead of sending to a fraction of the audience.
      post = basic_post_with_audience
      blast = create(:blast, :just_requested, post:)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)
      $redis.rpush("#{snapshot_key}:tmp", 1)

      expect(AudienceMember).to receive(:filter).and_call_original
      described_class.new.perform(blast.id)

      expect_sent_count 1
      expect($redis.exists?("#{snapshot_key}:tmp")).to eq(false)
      expect(blast.reload.completed_at).to be_present
    ensure
      $redis.del(snapshot_key, "#{snapshot_key}:tmp")
    end

    it "keeps the snapshot when the send fails so the retry can reuse it" do
      post = basic_post_with_audience
      blast = create(:blast, :just_requested, post:)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)

      allow(PostEmailApi).to receive(:provider_for).and_return(MailerInfo::EMAIL_PROVIDER_SENDGRID)
      expect(PostSendgridApi).to receive(:process).and_raise(StandardError.new("API failure"))
      expect do
        described_class.new.perform(blast.id)
      end.to raise_error(StandardError, "API failure")

      expect($redis.exists?(snapshot_key)).to eq(true)
    ensure
      $redis.del(snapshot_key)
    end

    it "keeps earlier provider sends when a later provider fails" do
      post = basic_post_with_audience
      first_follower = post.seller.followers.first
      second_follower = create(:active_follower, user: @seller)
      blast = create(:blast, :just_requested, post:)

      # `group_by` preserves first-seen order, so routing the first address the job asks
      # about to Resend is what puts the succeeding provider ahead of the failing one.
      # Keying on a fixed address instead would depend on the audience query's ordering.
      resend_email = nil
      allow(PostEmailApi).to receive(:provider_for) do |email:, **|
        resend_email ||= email
        email == resend_email ? MailerInfo::EMAIL_PROVIDER_RESEND : MailerInfo::EMAIL_PROVIDER_SENDGRID
      end
      allow(PostResendApi).to receive(:process)
      expect(PostSendgridApi).to receive(:process).and_raise(StandardError.new("API failure"))

      expect do
        described_class.new.perform(blast.id)
      end.to raise_error(StandardError, "API failure")

      emails = [first_follower.email, second_follower.email]
      failed_email = (emails - [resend_email]).sole
      # The provider that already accepted its slice keeps its rows; only the slice that
      # raised is rolled back.
      expect(SentPostEmail.where(post:, email: resend_email).count).to eq(1)
      expect(SentPostEmail.where(post:, email: failed_email).count).to eq(0)
      expect(blast.reload.completed_at).to be_blank
    end
  end

  describe "error handling" do
    it "deletes sent_post_emails records if a provider send raises an error" do
      # Setup post and blast
      post = create(:audience_post, :published, seller: @seller)
      create(:active_follower, user: @seller)
      blast = create(:blast, :just_requested, post: post)

      # Mock the provider send to raise an error
      allow(PostEmailApi).to receive(:provider_for).and_return(MailerInfo::EMAIL_PROVIDER_SENDGRID)
      expect(PostSendgridApi).to receive(:process).and_raise(StandardError.new("API failure"))

      # Run the job and expect it to raise the error
      expect do
        described_class.new.perform(blast.id)
      end.to raise_error(StandardError, "API failure")

      # Verify that no SentPostEmail records exist
      expect(SentPostEmail.where(post: post).count).to eq(0)
    end
  end

  describe ".fully_delivered?" do
    let(:blast) { create(:blast, post: basic_post_with_audience, completed_at: nil) }
    let(:pending_key) { RedisKey.blast_pending_recipients(blast.id) }

    it "is false when the sender never published an owed count" do
      expect(described_class.fully_delivered?(blast)).to be(false)
    end

    it "is false while recipients are still owed" do
      $redis.set(pending_key, 5)

      expect(described_class.fully_delivered?(blast)).to be(false)
    end

    it "is true once every recipient has been handed over" do
      $redis.set(pending_key, 0)

      expect(described_class.fully_delivered?(blast)).to be(true)
    end

    it "is true when the count went negative through a re-delivered slice" do
      $redis.set(pending_key, -2)

      expect(described_class.fully_delivered?(blast)).to be(true)
    end

    it "is false once completed_at is already set" do
      $redis.set(pending_key, 0)
      blast.update!(completed_at: Time.current)

      expect(described_class.fully_delivered?(blast)).to be(false)
    end

    it "is false for a non-opener resend that still owes recipients" do
      blast.update!(recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED)
      $redis.set(pending_key, 1)

      expect(described_class.fully_delivered?(blast)).to be(false)

      $redis.set(pending_key, 0)
      expect(described_class.fully_delivered?(blast)).to be(true)
    end
  end

  describe "members without an email" do
    # The provider raises on a blank recipient email, and every retry re-reads the same audience
    # and dies on the same slice, so one such row strands the whole blast (gumroad-private#2338).
    def blank_out_audience_email(email)
      AudienceMember.find_by!(seller: @seller, email:).update_column(:email, "")
    end

    it "delivers to the rest of the audience instead of raising" do
      post = create(:audience_post, :published, seller: @seller)
      create(:active_follower, user: @seller, email: "reachable@example.com")
      create(:active_follower, user: @seller, email: "blank@example.com")
      blank_out_audience_email("blank@example.com")
      blast = create(:blast, :just_requested, post:)

      described_class.new.perform(blast.id)

      expect_sent_count 1
      expect_sent_email "reachable@example.com"
      expect(blast.reload.completed_at).to be_present
    end

    it "completes a blast whose entire audience has no email" do
      post = create(:audience_post, :published, seller: @seller)
      create(:active_follower, user: @seller, email: "blank@example.com")
      blank_out_audience_email("blank@example.com")
      blast = create(:blast, :just_requested, post:)

      described_class.new.perform(blast.id)

      expect_sent_count 0
      expect(blast.reload.completed_at).to be_present
    end

    it "drops them on a non-opener resend too" do
      post = create(:audience_post, :published, seller: @seller)
      create(:active_follower, user: @seller, email: "reachable@example.com")
      create(:active_follower, user: @seller, email: "blank@example.com")
      blank_out_audience_email("blank@example.com")
      blast = create(:blast, :just_requested, post:, recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED)
      allow_any_instance_of(Installment).to receive(:unopened_recipient_emails).and_return(["reachable@example.com", ""])

      described_class.new.perform(blast.id)

      expect_sent_count 1
      expect_sent_email "reachable@example.com"
    end
  end

  describe "one large blast per seller per day" do
    it "holds a second large blast until tomorrow" do
      blast = create(:blast, :just_requested, post: basic_post_with_audience)
      allow(SellerLargeBlastQuota).to receive(:allow?).and_return(false)

      described_class.new.perform(blast.id)

      expect(PostSendgridApi.mails).to be_empty
      expect(described_class).to have_enqueued_sidekiq_job(blast.id).at(Time.zone.tomorrow.beginning_of_day)
      expect(blast.reload.completed_at).to be_nil
    end
  end

  describe "splitting large blasts into slice jobs" do
    # Each example builds its own seller + audience so follower counts are exact and no
    # example's audience leaks into the next (the audience filter is all-of-the-seller's).
    def audience_post_with_followers(count)
      seller = create(:named_user)
      post = create(:audience_post, :published, seller:)
      create_list(:active_follower, count, user: seller)
      [post, seller]
    end

    it "enqueues one slice job per chunk and sends nothing inline" do
      post, = audience_post_with_followers(2_002)
      blast = create(:blast, :just_requested, post:)

      described_class.new.perform(blast.id)

      jobs = SendPostBlastEmailsSliceJob.jobs.map { _1["args"] }
      expect(jobs.size).to eq(2)
      expect(jobs.first[0]).to eq(blast.id)
      expect(jobs.first[1]).to match(/\A[0-9a-f]{64}\z/)
      expect(jobs.first[1]).to eq(jobs.last[1])
      expect($redis.get(RedisKey.blast_active_slice_partition(blast.id))).to eq(jobs.first[1])
      stored_chunks = $redis.lrange(RedisKey.blast_slice_partition_chunks(blast.id, jobs.first[1]), 0, -1).map { JSON.parse(_1) }
      expect(stored_chunks).to eq(jobs.map(&:last))
      expect(jobs.first[2, 2]).to eq([0, 2])
      expect(jobs.last[2, 2]).to eq([1, 2])
      # The chunks are disjoint and cover the whole filtered audience, in order.
      expect(jobs.first.last.size).to eq(2_000)
      expect(jobs.last.last.size).to eq(2)
      expect((jobs.first.last + jobs.last.last).uniq.size).to eq(2_002)
      expect(PostSendgridApi.mails).to be_empty
      # The parent only distributes; the last slice job stamps completion.
      expect(blast.reload.completed_at).to be_nil
      expect(blast.reload.started_at).to be_present
    end

    it "holds the partition mutation lock while publishing a replacement partition" do
      post, = audience_post_with_followers(2_002)
      blast = create(:blast, :just_requested, post:)
      lock_key = RedisKey.blast_slice_partition_mutation_lock(blast.id)
      lock_was_held = nil
      job = described_class.new
      allow(job).to receive(:write_slice_partition).and_wrap_original do |original, partition_key, chunks|
        lock_was_held = !$redis.set(lock_key, "intruder", nx: true, ex: 10)
        original.call(partition_key, chunks)
      end

      job.perform(blast.id)

      expect(lock_was_held).to be(true)
      expect(SendPostBlastEmailsSliceJob.jobs.size).to eq(2)
    ensure
      $redis.del(lock_key) if lock_key
    end

    it "publishes the full owed count for the slice jobs to decrement" do
      post, = audience_post_with_followers(2_002)
      blast = create(:blast, :just_requested, post:)
      pending_key = RedisKey.blast_pending_recipients(blast.id)

      described_class.new.perform(blast.id)

      expect($redis.get(pending_key).to_i).to eq(2_002)
    ensure
      $redis.del(pending_key)
    end

    it "reuses an active partition instead of repartitioning a parent retry" do
      post, = audience_post_with_followers(11)
      $redis.set(RedisKey.blast_child_split_threshold, 10)
      $redis.set(RedisKey.blast_child_slice_size, 6)
      blast = create(:blast, :just_requested, post:)
      pending_key = RedisKey.blast_pending_recipients(blast.id)

      described_class.new.perform(blast.id)
      first_jobs = SendPostBlastEmailsSliceJob.jobs.map { _1["args"] }
      partition_key = first_jobs.first[1]
      $redis.set(pending_key, 7)
      SendPostBlastEmailsSliceJob.jobs.clear

      # The stored chunks already fix the recipients; the retry must not reload or
      # revalidate the audience just to discard it.
      expect(AudienceMember).not_to receive(:filter)
      described_class.new.perform(blast.id)

      expect(SendPostBlastEmailsSliceJob.jobs.map { _1["args"] }).to eq(first_jobs)
      expect($redis.get(RedisKey.blast_active_slice_partition(blast.id))).to eq(partition_key)
      expect($redis.get(pending_key).to_i).to eq(7)
    ensure
      $redis.del(RedisKey.blast_child_split_threshold, RedisKey.blast_child_slice_size, pending_key)
    end

    it "repartitions from a fresh audience load when the active partition's chunk list has expired" do
      post, = audience_post_with_followers(11)
      $redis.set(RedisKey.blast_child_split_threshold, 10)
      $redis.set(RedisKey.blast_child_slice_size, 6)
      blast = create(:blast, :just_requested, post:)
      $redis.set(RedisKey.blast_active_slice_partition(blast.id), "expired-chunks-partition")

      described_class.new.perform(blast.id)

      jobs = SendPostBlastEmailsSliceJob.jobs.map { _1["args"] }
      expect(jobs.size).to eq(2)
      expect(jobs.first[1]).not_to eq("expired-chunks-partition")
      expect($redis.get(RedisKey.blast_active_slice_partition(blast.id))).to eq(jobs.first[1])
    ensure
      $redis.del(RedisKey.blast_child_split_threshold, RedisKey.blast_child_slice_size)
    end

    it "reuses a partition another parent published while this parent loaded the audience" do
      post, seller = audience_post_with_followers(11)
      $redis.set(RedisKey.blast_child_split_threshold, 10)
      $redis.set(RedisKey.blast_child_slice_size, 6)
      blast = create(:blast, :just_requested, post:)
      existing_partition_key = "existing-partition"
      existing_chunks = AudienceMember.where(seller_id: seller).limit(2).pluck(:id).map { [_1] }
      installed_existing_partition = false
      allow(AudienceMember).to receive(:filter).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap do
          unless installed_existing_partition
            $redis.rpush(RedisKey.blast_slice_partition_chunks(blast.id, existing_partition_key), existing_chunks.map(&:to_json))
            $redis.set(RedisKey.blast_active_slice_partition(blast.id), existing_partition_key)
            installed_existing_partition = true
          end
        end
      end

      described_class.new.perform(blast.id)

      jobs = SendPostBlastEmailsSliceJob.jobs.map { _1["args"] }
      expect(jobs.map { _1[1] }).to eq([existing_partition_key, existing_partition_key])
      expect(jobs.map(&:last)).to eq(existing_chunks)
      expect($redis.get(RedisKey.blast_active_slice_partition(blast.id))).to eq(existing_partition_key)
    ensure
      $redis.del(RedisKey.blast_child_split_threshold, RedisKey.blast_child_slice_size,
                 RedisKey.blast_active_slice_partition(blast.id),
                 RedisKey.blast_slice_partition_chunks(blast.id, existing_partition_key)) if blast
    end

    it "checks already-emailed recipients in bounded IN-list batches" do
      stub_const("PostBlastSending::ALREADY_EMAILED_SLICE_SIZE", 2)
      post, = audience_post_with_followers(5)
      blast = create(:blast, :just_requested, post:)
      batch_sizes = []
      allow_any_instance_of(Installment).to receive(:sent_post_emails).and_wrap_original do |original|
        original.call.tap do |relation|
          allow(relation).to receive(:where).and_wrap_original do |where_original, *args, **kwargs|
            emails = kwargs[:email] || args.first&.[](:email)
            batch_sizes << Array(emails).size if emails
            where_original.call(*args, **kwargs)
          end
        end
      end
      allow_any_instance_of(described_class).to receive(:send_members)

      described_class.new.perform(blast.id)

      expect(batch_sizes).to all(be <= 2)
      expect(batch_sizes.sum).to eq(5)
    end

    it "completes inline blasts without a slice partition" do
      post, = audience_post_with_followers(1)
      blast = create(:blast, :just_requested, post:)
      allow_any_instance_of(described_class).to receive(:send_members)

      described_class.new.perform(blast.id)

      expect(blast.reload.completed_at).to be_present
      expect($redis.exists?(RedisKey.blast_active_slice_partition(blast.id))).to be(false)
    end

    it "sends inline for a blast at or under the split threshold" do
      post, = audience_post_with_followers(2_000) # right at the threshold
      blast = create(:blast, :just_requested, post:)

      described_class.new.perform(blast.id)

      expect(SendPostBlastEmailsSliceJob.jobs).to be_empty
      expect_sent_count 2_000
      expect(blast.reload.completed_at).to be_present
    end

    it "splits at the Redis-tunable threshold override" do
      post, = audience_post_with_followers(11)
      $redis.set(RedisKey.blast_child_split_threshold, 10)
      $redis.set(RedisKey.blast_child_slice_size, 6) # 11 members -> ceil(11/6) = 2 slices
      blast = create(:blast, :just_requested, post:)

      described_class.new.perform(blast.id)

      jobs = SendPostBlastEmailsSliceJob.jobs.map { _1["args"] }
      expect(jobs.size).to eq(2)
      expect(jobs.map { _1[3] }).to eq([2, 2])
      expect(jobs.map { _1.last.size }).to eq([6, 5])
      expect(PostSendgridApi.mails).to be_empty
    ensure
      $redis.del(RedisKey.blast_child_split_threshold, RedisKey.blast_child_slice_size)
    end

    it "respects the Redis-tunable slice size" do
      post, = audience_post_with_followers(2_002)
      $redis.set(RedisKey.blast_child_slice_size, 1_000)
      blast = create(:blast, :just_requested, post:)

      described_class.new.perform(blast.id)

      jobs = SendPostBlastEmailsSliceJob.jobs.map { _1["args"] }
      expect(jobs.size).to eq(3)
      expect(jobs.map { _1.last.size }).to eq([1_000, 1_000, 2])
    ensure
      $redis.del(RedisKey.blast_child_slice_size)
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
