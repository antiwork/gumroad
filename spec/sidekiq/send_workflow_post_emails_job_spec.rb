# frozen_string_literal: true

require "spec_helper"

describe SendWorkflowPostEmailsJob, :freeze_time do
  before do
    @seller = create(:named_user)
    @workflow = create(:audience_workflow, seller: @seller)
    @post = create(:audience_post, :published, workflow: @workflow, seller: @seller)
    @post_rule = create(:post_rule, installment: @post, delayed_delivery_time: 1.day)
  end

  describe "#perform with a follower" do
    before do
      followed_at = 2.days.ago
      @basic_follower = create(:active_follower, user: @seller, created_at: followed_at, confirmed_at: followed_at)
    end

    it "ignores deleted workflows" do
      @workflow.mark_deleted!
      described_class.new.perform(@post.id)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
    end

    it "ignores deleted posts" do
      @post.mark_deleted!
      described_class.new.perform(@post.id)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
    end

    it "ignores unpublished posts" do
      @post.update!(published_at: nil)
      described_class.new.perform(@post.id)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
    end

    it "reads the primary database for a versioned reschedule scan" do
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original

      described_class.new.perform(@post.id, nil, true, @post_rule.version)
    end

    it "keeps a recipient repair scan on the primary connection" do
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).ordered.and_call_original
      expect(WithMaxExecutionTime).to receive(:timeout_queries).ordered.and_call_original
      expect(Makara::Context).to receive(:release_all).ordered

      described_class.new.perform(@post.id, 1.day.ago.iso8601)
    end

    it "keeps a repair scan without a cutoff on the primary connection" do
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).ordered.and_call_original
      expect(WithMaxExecutionTime).to receive(:timeout_queries).ordered.and_call_original
      expect(Makara::Context).to receive(:release_all).ordered

      described_class.new.perform(@post.id, nil, true)
    end

    it "retries if the required rule version is not visible" do
      expect do
        described_class.new.perform(@post.id, nil, true, @post_rule.version + 1)
      end.to raise_error(SendWorkflowPostEmailsJob::RuleNotCommittedError)
    end

    it "only considers audience members created after the earliest_valid_time" do
      described_class.new.perform(@post.id, 1.day.ago.iso8601)
      expect(SendWorkflowInstallmentWorker.jobs).to be_empty

      described_class.new.perform(@post.id, 3.days.ago.iso8601)
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        @basic_follower.id,
        nil,
        nil,
        @basic_follower.confirmed_at.iso8601
      )

      # does not limit when earliest_valid_time is nil
      SendWorkflowInstallmentWorker.jobs.clear
      described_class.new.perform(@post.id, nil)
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        @basic_follower.id,
        nil,
        nil,
        @basic_follower.confirmed_at.iso8601
      )
    end

    it "preserves the trigger time for recipients from a reschedule" do
      described_class.new.perform(@post.id, nil, true)

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        @basic_follower.id,
        nil,
        nil,
        @basic_follower.confirmed_at.iso8601
      ).immediately
    end

    it "includes a follower who confirmed after the reschedule cutoff" do
      @basic_follower.update_columns(created_at: 3.days.ago)
      @basic_follower.update!(confirmed_at: 1.hour.ago)
      cutoff = 1.day.ago

      described_class.new.perform(@post.id, cutoff.iso8601, true)

      expect(@basic_follower.created_at).to be < cutoff
      expect(@basic_follower.confirmed_at).to be > cutoff
      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        @basic_follower.id,
        nil,
        nil,
        @basic_follower.confirmed_at.iso8601
      ).at(@basic_follower.confirmed_at + @post_rule.delayed_delivery_time)
    end

    it "preserves the follower trigger when purchase filters hide a recovered follower id" do
      product = create(:product, user: @seller, price_cents: 0)
      purchase = create(:free_purchase, link: product, email: @basic_follower.email, created_at: 3.days.ago)
      purchase.add_to_audience_member_details
      @post.update!(bought_products: [product.unique_permalink])
      @basic_follower.update_columns(created_at: 3.days.ago)
      @basic_follower.update!(confirmed_at: 1.hour.ago)
      cutoff = 1.day.ago

      described_class.new.perform(@post.id, cutoff.iso8601, true)

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        @basic_follower.id,
        nil,
        nil,
        @basic_follower.confirmed_at.iso8601
      ).at(@basic_follower.confirmed_at + @post_rule.delayed_delivery_time)
    end

    it "merges a recovered follower trigger into an ordinary audience member" do
      product = create(:product, user: @seller, price_cents: 0)
      purchase = create(:free_purchase, link: product, email: @basic_follower.email, created_at: 30.minutes.ago)
      purchase.add_to_audience_member_details
      @post.update!(bought_products: [product.unique_permalink])
      @basic_follower.update_columns(created_at: 3.days.ago)
      @basic_follower.update!(confirmed_at: 1.hour.ago)
      cutoff = 1.day.ago
      ordinary_member = AudienceMember.filter(
        seller_id: @seller.id,
        params: @post.audience_members_filter_params.merge(created_after: cutoff),
        with_ids: true
      ).sole
      expect(ordinary_member.purchase_id).to eq(purchase.id)
      expect(ordinary_member.follower_id).to be_nil

      described_class.new.perform(@post.id, cutoff.iso8601, true)

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        @basic_follower.id,
        nil,
        nil,
        @basic_follower.confirmed_at.iso8601
      ).at(@basic_follower.confirmed_at + @post_rule.delayed_delivery_time)
    end

    it "does not replace a qualifying purchase with a follower outside the workflow dates" do
      product = create(:product, user: @seller, price_cents: 0)
      purchase = create(:free_purchase, link: product, email: @basic_follower.email, created_at: 30.minutes.ago)
      purchase.add_to_audience_member_details
      @post.update!(bought_products: [product.unique_permalink], created_after: 2.days.ago.to_date.iso8601)
      @basic_follower.update_columns(created_at: 3.days.ago)
      @basic_follower.update!(confirmed_at: 1.hour.ago)

      described_class.new.perform(@post.id, 1.day.ago.iso8601, true)

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        purchase.id,
        nil,
        nil,
        nil,
        purchase.created_at.iso8601
      ).at(purchase.created_at + @post_rule.delayed_delivery_time)
    end

    it "loads follower confirmation times in bounded queries" do
      second_follower = create(:active_follower, user: @seller, created_at: 1.day.ago, confirmed_at: 1.day.ago)
      third_follower = create(:active_follower, user: @seller, created_at: 1.day.ago, confirmed_at: 1.day.ago)
      stub_const("#{described_class}::FOLLOWER_LOOKUP_BATCH_SIZE", 2)
      queried_ids = []
      allow(Follower).to receive(:where).and_wrap_original do |method, id:|
        queried_ids << id
        method.call(id:)
      end

      described_class.new.perform(@post.id)

      expect(queried_ids.map(&:size)).to eq([2, 1])
      expect(queried_ids.flatten).to contain_exactly(@basic_follower.id, second_follower.id, third_follower.id)
    end
  end

  describe "#perform with an affiliate" do
    before do
      @product = create(:product, user: @seller)
      @affiliate = create(:direct_affiliate, seller: @seller, send_posts: true, created_at: 5.days.ago)
      @product_affiliate = create(:product_affiliate, affiliate: @affiliate, product: @product, created_at: 2.hours.ago)
      @post.update!(installment_type: Installment::AFFILIATE_TYPE, affiliate_products: [@product.unique_permalink])
    end

    it "schedules from the product affiliation time" do
      described_class.new.perform(@post.id)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id
      ).at(@product_affiliate.created_at + @post_rule.delayed_delivery_time)
    end

    it "uses the product relation for the workflow cutoff" do
      described_class.new.perform(@post.id, 3.hours.ago.iso8601)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id
      ).at(@product_affiliate.created_at + @post_rule.delayed_delivery_time)
    end

    it "uses the current product relation for a scoped audience workflow" do
      @post.update!(installment_type: Installment::AUDIENCE_TYPE)

      described_class.new.perform(@post.id, 3.hours.ago.iso8601)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id
      ).at(@product_affiliate.created_at + @post_rule.delayed_delivery_time)
    end

    it "uses the current product relation for an unscoped audience workflow" do
      @post.update!(installment_type: Installment::AUDIENCE_TYPE, affiliate_products: nil)

      described_class.new.perform(@post.id, 3.hours.ago.iso8601)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id
      ).at(@product_affiliate.created_at + @post_rule.delayed_delivery_time)
    end

    it "does not replace a qualifying purchase with an affiliate outside the workflow dates" do
      purchase = create(:free_purchase, link: @product, email: @affiliate.affiliate_user.email, created_at: 1.hour.ago)
      purchase.add_to_audience_member_details
      @post.update!(
        installment_type: Installment::AUDIENCE_TYPE,
        affiliate_products: nil,
        created_after: 3.days.ago.to_date.iso8601
      )

      described_class.new.perform(@post.id, 3.hours.ago.iso8601, true)

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        purchase.id,
        nil,
        nil,
        nil,
        purchase.created_at.iso8601
      ).at(purchase.created_at + @post_rule.delayed_delivery_time)
    end

    it "keeps user date filters on the affiliate creation time" do
      @post.update!(created_after: 3.days.ago.to_date.iso8601)

      described_class.new.perform(@post.id)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
    end

    it "repairs product assignments from the publication second" do
      @product_affiliate.update_columns(created_at: @post.published_at)

      described_class.new.perform(@post.id, @post.published_at.iso8601)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id
      ).at(@post.published_at + @post_rule.delayed_delivery_time)
    end
  end

  describe "#perform" do
    context "for different post types" do
      before do
        @products = []
        @products << create(:product, user: @seller, name: "Product one")
        @products << create(:product, user: @seller, name: "Product two")
        category = create(:variant_category, link: @products[0])
        @variants = create_list(:variant, 2, variant_category: category)
        @products << create(:product, :is_subscription, user: @seller, name: "Product three")

        @sales = []
        @sales << create(:purchase, link: @products[0], created_at: 7.days.ago)
        @sales << create(:purchase, link: @products[1], email: @sales[0].email, created_at: 6.days.ago)
        @sales << create(:purchase, link: @products[0], created_at: 5.days.ago)
        @sales << create(:purchase, link: @products[1], variant_attributes: [@variants[0]], created_at: 4.days.ago)
        @sales << create(:purchase, link: @products[1], variant_attributes: [@variants[1]], created_at: 3.days.ago)
        @sales << create(:membership_purchase, link: @products[2], created_at: 6.hours.ago)

        @followers = []
        @followers << create(:active_follower, user: @seller, created_at: 5.days.ago, confirmed_at: 5.days.ago)
        @followers << create(:active_follower, user: @seller, email: @sales[0].email, created_at: 5.hours.ago, confirmed_at: 5.hours.ago)

        @affiliates = []
        @affiliates << create(:direct_affiliate, seller: @seller, send_posts: true, created_at: 4.hours.ago)
        @affiliates[0].products << @products[0]
        @affiliates[0].products << @products[1]
        @affiliate_trigger_time = @affiliates[0].product_affiliates.maximum(:created_at).change(usec: 0)

        # Basic check for working recipient filtering.
        # The details of it are tested in the Installment model specs.
        create(:deleted_follower, user: @seller)
        create(:purchase, link: @products[0], can_contact: false)
        create(:direct_affiliate, seller: @seller, send_posts: false).products << @products[0]
        create(:membership_purchase, email: @sales[5].email, link: @products[2], subscription: @sales[5].subscription, is_original_subscription_purchase: false)
      end

      it "when product_type? is true, it enqueues the expected emails at the right times" do
        @post.update!(installment_type: Installment::PRODUCT_TYPE, link: @products[0], bought_products: [@products[0].unique_permalink])
        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(2)
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[0].id, nil, nil).immediately
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[2].id, nil, nil).immediately

        SendWorkflowInstallmentWorker.jobs.clear
        @post.update!(installment_type: Installment::PRODUCT_TYPE, link: @products[2], bought_products: [@products[2].unique_permalink])
        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[5].id, nil, nil).at(18.hours.from_now)
      end

      it "when variant_type? is true, it sends the expected emails at the right times" do
        @post.update!(installment_type: Installment::VARIANT_TYPE, link: @products[1], base_variant: @variants[0], bought_variants: [@variants[0].external_id])
        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[3].id, nil, nil).immediately
      end

      it "when seller_type? is true, it sends the expected emails at the right times" do
        @post.update!(installment_type: Installment::SELLER_TYPE)
        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(5)
        [1, 2, 3, 4].each do |sale_index|
          expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[sale_index].id, nil, nil).immediately
        end
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[5].id, nil, nil).at(18.hours.from_now)
      end

      it "when follower_type? is true, it sends the expected emails at the right times" do
        @post.update!(installment_type: Installment::FOLLOWER_TYPE)
        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(2)
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, @followers[0].id, nil, nil, @followers[0].confirmed_at.iso8601).immediately
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, @followers[1].id, nil, nil, @followers[1].confirmed_at.iso8601).at(19.hours.from_now)
      end

      it "when follower_type? is true and a bought-product filter is set, it still sends to the matching follower" do
        @post.update!(installment_type: Installment::FOLLOWER_TYPE, bought_products: [@products[0].unique_permalink])
        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, @followers[1].id, nil, nil, @followers[1].confirmed_at.iso8601).at(19.hours.from_now)
      end

      it "when affiliate_type? is true, it sends the expected emails at the right times" do
        @post.update!(installment_type: Installment::AFFILIATE_TYPE, affiliate_products: [@products[0].unique_permalink])
        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, nil, @affiliates[0].affiliate_user_id).at(@affiliate_trigger_time + @post_rule.delayed_delivery_time)
      end

      it "when affiliate_type? is true and a bought-product filter is set, it still resolves the matching affiliate" do
        create(:purchase, link: @products[0], email: @affiliates[0].affiliate_user.email, created_at: 2.hours.ago)
        @post.update!(installment_type: Installment::AFFILIATE_TYPE, affiliate_products: [@products[0].unique_permalink], bought_products: [@products[0].unique_permalink])

        member = AudienceMember.filter(seller_id: @post.seller_id, params: @post.audience_members_filter_params, with_ids: true).sole
        expect(member.affiliate_id).to eq(@affiliates[0].id)

        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, nil, @affiliates[0].affiliate_user_id).at(@affiliate_trigger_time + @post_rule.delayed_delivery_time)
      end

      it "enqueues an affiliate id the worker can actually resolve to a user" do
        @post.update!(installment_type: Installment::AFFILIATE_TYPE, affiliate_products: [@products[0].unique_permalink])
        described_class.new.perform(@post.id)

        # The worker resolves this argument with User.find_by, so a DirectAffiliate id here
        # lands on whichever unrelated user happens to share that number, or on nobody.
        enqueued_id = SendWorkflowInstallmentWorker.jobs.last["args"].last
        expect(User.find_by(id: enqueued_id)).to eq(@affiliates[0].affiliate_user)
        expect(enqueued_id).not_to eq(@affiliates[0].id)
      end

      it "when the affiliate id is missing from the join, it falls back to an affiliate entry for one of the post's products" do
        @post.update!(installment_type: Installment::AFFILIATE_TYPE, affiliate_products: [@products[0].unique_permalink])

        member = AudienceMember.find_by!(seller: @seller, email: @affiliates[0].affiliate_user.email)
        # A member accumulates one `details["affiliates"]` entry per (affiliate relationship,
        # product) pair, and an entry for a relationship that has since been replaced can still be
        # sitting in the JSON. Here the leftover entry is for a product this post is not about and
        # carries a higher id and a different created_at, so a fallback that just takes the newest
        # entry on the member would pick it.
        details = member.details.deep_dup
        details["affiliates"] = [
          { "id" => @affiliates[0].id, "product_id" => @products[0].id, "created_at" => 4.hours.ago.iso8601 },
          { "id" => @affiliates[0].id + 1_000, "product_id" => @products[2].id, "created_at" => 1.hour.ago.iso8601 },
        ]
        # Reproduce the case Greptile flagged: the member still qualifies, but the aggregate over
        # the JSON_TABLE join hands back a NULL affiliate id, so the job resolves it itself.
        allow(member).to receive(:details).and_return(details)
        allow(member).to receive(:affiliate_id).and_return(nil)
        allow(AudienceMember).to receive(:filter).and_return(double(select: [member]))

        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, nil, @affiliates[0].affiliate_user_id).at(@affiliate_trigger_time + @post_rule.delayed_delivery_time)
      end

      it "when the affiliate id is missing and nothing on the member is in scope, it skips them instead of sending" do
        @post.update!(installment_type: Installment::AFFILIATE_TYPE, affiliate_products: [@products[0].unique_permalink])

        member = AudienceMember.find_by!(seller: @seller, email: @affiliates[0].affiliate_user.email)
        # Every entry left on the member is for a product this post is not about. There is no
        # legitimate affiliate to send as, so the job must skip rather than reach for one of them.
        details = member.details.deep_dup
        details["affiliates"] = [
          { "id" => @affiliates[0].id + 1_000, "product_id" => @products[2].id, "created_at" => 1.hour.ago.iso8601 },
        ]
        allow(member).to receive(:details).and_return(details)
        allow(member).to receive(:affiliate_id).and_return(nil)
        allow(AudienceMember).to receive(:filter).and_return(double(select: [member]))

        expect(Rails.logger).to receive(:error).with(/could not resolve a affiliate recipient/)

        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs).to be_empty
      end

      it "when audience_type? is true, it sends the expected emails at the right times" do
        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(7)

        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, @followers[0].id, nil, nil, @followers[0].confirmed_at.iso8601).immediately
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, @followers[1].id, nil, nil, @followers[1].confirmed_at.iso8601).at(19.hours.from_now)

        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, nil, @affiliates[0].affiliate_user_id).at(@affiliate_trigger_time + @post_rule.delayed_delivery_time)

        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[2].id, nil, nil).immediately
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[3].id, nil, nil).immediately
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[4].id, nil, nil).immediately
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[5].id, nil, nil).at(18.hours.from_now)
      end

      it "loads the audience with a raised statement execution cap" do
        expect(WithMaxExecutionTime).to receive(:timeout_queries).with(seconds: 1.hour.to_i).and_call_original
        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(7)
      end
    end
  end
end
