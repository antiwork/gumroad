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
      followed_at = 2.days.ago.change(usec: 0)
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

    it "reads the primary database for a required rule version" do
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original

      described_class.new.perform(@post.id, nil, false, @post_rule.version)
    end

    it "keeps a cutoff scan on the primary database until the audience loads" do
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).ordered.and_call_original
      expect(WithMaxExecutionTime).to receive(:timeout_queries).exactly(3).times.ordered.and_call_original
      expect(Makara::Context).to receive(:release_all).ordered

      described_class.new.perform(@post.id, 1.day.ago.iso8601)
    end

    it "retries if the required rule version is not visible" do
      expect do
        described_class.new.perform(@post.id, nil, false, @post_rule.version + 1)
      end.to raise_error(described_class::RuleNotCommittedError)
    end

    it "continues when the version cache is unavailable" do
      error = Redis::BaseError.new("cache unavailable")
      allow_any_instance_of(InstallmentRule).to receive(:cache_version!).and_raise(error)
      expect(ErrorNotifier).to receive(:notify).with(error, installment_rule_id: @post_rule.id)

      described_class.new.perform(@post.id)

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

    it "only considers confirmations after the earliest valid time" do
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

    it "recovers a follower who confirmed after the cutoff" do
      @basic_follower.update_columns(created_at: 3.days.ago)
      @basic_follower.update!(confirmed_at: 1.hour.ago.change(usec: 0))
      cutoff = 1.day.ago

      described_class.new.perform(@post.id, cutoff.iso8601)

      expect(@basic_follower.created_at).to be < cutoff
      expect(@basic_follower.confirmed_at).to be > cutoff
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        @basic_follower.id,
        nil,
        nil,
        @basic_follower.confirmed_at.iso8601
      ).at(@basic_follower.confirmed_at + @post_rule.delayed_delivery_time)
    end

    it "does not rematerialize a follower already selected by the cutoff" do
      allow(AudienceMember).to receive(:filter).and_call_original
      expect(AudienceMember).to receive(:filter).once.with(
        seller_id: @seller.id,
        params: anything,
        with_ids: true,
        ids: anything
      ).and_call_original

      described_class.new.perform(@post.id, 3.days.ago.iso8601)
    end

    it "checks fanout ownership between cutoff scans" do
      @basic_follower.update_columns(created_at: 3.days.ago)
      @basic_follower.update!(confirmed_at: 1.hour.ago.change(usec: 0))
      job = described_class.new
      expect(job).to receive(:renew_fanout_lease).at_least(6).times.and_call_original

      job.perform(@post.id, 1.day.ago.iso8601)
    end

    it "recovers a follower confirmed in the publication second" do
      published_at = Time.current.change(usec: 0)
      @post.update!(
        installment_type: Installment::FOLLOWER_TYPE,
        published_at:,
        is_for_new_customers_of_workflow: true
      )
      @basic_follower.update_columns(created_at: 1.day.ago, confirmed_at: published_at)

      described_class.new.perform(@post.id, published_at.iso8601)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        @basic_follower.id,
        nil,
        nil,
        published_at.iso8601
      ).at(published_at + @post_rule.delayed_delivery_time)
    end

    it "recovers a follower confirmed in the cutoff second" do
      cutoff = Time.current.change(usec: 500_000)
      confirmed_at = cutoff.change(usec: 0)
      @basic_follower.update_columns(created_at: 1.day.ago, confirmed_at:)

      described_class.new.perform(@post.id, cutoff.iso8601(6))

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        @basic_follower.id,
        nil,
        nil,
        confirmed_at.iso8601
      ).at(confirmed_at + @post_rule.delayed_delivery_time)
    end

    it "recovers a follower id hidden by purchase filters" do
      product = create(:product, user: @seller, price_cents: 0)
      purchase = create(:free_purchase, link: product, email: @basic_follower.email, created_at: 3.days.ago)
      purchase.rebuild_audience_member_details
      @post.update!(installment_type: Installment::FOLLOWER_TYPE, bought_products: [product.unique_permalink])
      @basic_follower.update_columns(created_at: 3.days.ago)
      @basic_follower.update!(confirmed_at: 1.hour.ago.change(usec: 0))

      described_class.new.perform(@post.id, 1.day.ago.iso8601)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        @basic_follower.id,
        nil,
        nil,
        @basic_follower.confirmed_at.iso8601
      ).at(@basic_follower.confirmed_at + @post_rule.delayed_delivery_time)
    end

    it "recovers a follower in range when the required purchase predates the range" do
      product = create(:product, user: @seller, price_cents: 0)
      purchase = create(:free_purchase, link: product, email: @basic_follower.email, created_at: 3.days.ago)
      purchase.rebuild_audience_member_details
      @post.update!(created_after: 3.days.ago, bought_products: [product.unique_permalink])
      @basic_follower.update!(confirmed_at: 1.hour.ago.change(usec: 0))

      described_class.new.perform(@post.id, 1.day.ago.iso8601)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        @basic_follower.id,
        nil,
        nil,
        @basic_follower.confirmed_at.iso8601
      ).at(@basic_follower.confirmed_at + @post_rule.delayed_delivery_time)
    end

    it "preserves a qualifying purchase for an audience workflow" do
      product = create(:product, user: @seller, price_cents: 0)
      purchase = create(:free_purchase, link: product, email: @basic_follower.email, created_at: 30.minutes.ago)
      purchase.rebuild_audience_member_details
      @basic_follower.update_columns(created_at: 3.days.ago)
      @basic_follower.update!(confirmed_at: 1.hour.ago.change(usec: 0))

      described_class.new.perform(@post.id, 1.day.ago.iso8601)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        purchase.id,
        nil,
        nil
      ).at(purchase.created_at + @post_rule.delayed_delivery_time)
      expect(SendWorkflowInstallmentWorker.jobs.none? { _1["args"][3] == @basic_follower.id }).to be(true)
    end

    it "keeps workflow date filters on the follower identity" do
      product = create(:product, user: @seller, price_cents: 0)
      purchase = create(:free_purchase, link: product, email: @basic_follower.email, created_at: 36.hours.ago)
      purchase.rebuild_audience_member_details
      @post.update!(created_after: 2.days.ago)
      @basic_follower.update_columns(created_at: 3.days.ago)
      @basic_follower.update!(confirmed_at: 1.hour.ago.change(usec: 0))

      described_class.new.perform(@post.id, 1.day.ago.iso8601)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
    end

    it "loads follower confirmation times in bounded queries" do
      second_follower = create(:active_follower, user: @seller, created_at: 1.day.ago, confirmed_at: 1.day.ago)
      third_follower = create(:active_follower, user: @seller, created_at: 1.day.ago, confirmed_at: 1.day.ago)
      stub_const("#{described_class}::FOLLOWER_LOOKUP_BATCH_SIZE", 2)
      queried_ids = []
      allow(Follower).to receive(:where).and_wrap_original do |method, id:, followed_id:|
        queried_ids << id
        method.call(id:, followed_id:)
      end

      described_class.new.perform(@post.id)

      expect(queried_ids.map(&:size)).to eq([2, 1])
      expect(queried_ids.flatten).to contain_exactly(@basic_follower.id, second_follower.id, third_follower.id)
    end

    it "preserves the follower confirmation time during a reschedule scan" do
      described_class.new.perform(@post.id, nil, true, @post_rule.version)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
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

    it "repairs a follower confirmed in the publication second" do
      published_at = Time.current.change(usec: 0)
      @post.update!(published_at:, is_for_new_customers_of_workflow: true)
      @basic_follower.update_columns(created_at: 1.day.ago, confirmed_at: published_at)

      described_class.new.perform(@post.id, published_at.iso8601, true, @post_rule.version)

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        @basic_follower.id,
        nil,
        nil,
        published_at.iso8601
      ).at(published_at + @post_rule.delayed_delivery_time)
    end

    it "repairs a follower before the old job after a shorter delay edit" do
      old_delay = 7.days
      old_deliver_at = @basic_follower.confirmed_at + old_delay
      @post_rule.update!(delayed_delivery_time: 1.hour)

      described_class.new.perform(@post.id, (Time.current - old_delay).iso8601, true, @post_rule.version)

      expect(old_deliver_at).to be > Time.current
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
  end

  describe "#perform with an affiliate" do
    before do
      @product = create(:product, user: @seller)
      @affiliate = create(:direct_affiliate, seller: @seller, send_posts: true, created_at: 5.days.ago)
      @product_affiliate = create(:product_affiliate, affiliate: @affiliate, product: @product, created_at: 2.hours.ago)
      @post.update!(installment_type: Installment::AFFILIATE_TYPE, affiliate_products: [@product.unique_permalink])
    end

    it "schedules from the product assignment time" do
      described_class.new.perform(@post.id)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id,
        nil,
        @product_affiliate.created_at.iso8601
      ).at(@product_affiliate.created_at + @post_rule.delayed_delivery_time)
    end

    it "preserves each distinct product assignment trigger" do
      other_product = create(:product, user: @seller)
      older_assignment = create(:product_affiliate, affiliate: @affiliate, product: other_product, created_at: 3.hours.ago)
      @post.update!(affiliate_products: [])

      described_class.new.perform(@post.id)

      reference_times = SendWorkflowInstallmentWorker.jobs.map { _1["args"][6] }
      expect(reference_times).to contain_exactly(older_assignment.created_at.iso8601, @product_affiliate.created_at.iso8601)
    end

    it "uses the product assignment for the fanout cutoff" do
      described_class.new.perform(@post.id, 3.hours.ago.iso8601)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id,
        nil,
        @product_affiliate.created_at.iso8601
      ).at(@product_affiliate.created_at + @post_rule.delayed_delivery_time)
    end

    it "includes product assignments from the cutoff second" do
      cutoff = @product_affiliate.created_at + 0.5.seconds

      described_class.new.perform(@post.id, cutoff.iso8601(6))

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id,
        nil,
        @product_affiliate.created_at.iso8601
      ).at(@product_affiliate.created_at + @post_rule.delayed_delivery_time)
    end

    it "uses the product assignment cutoff for an audience workflow" do
      @post.update!(installment_type: Installment::AUDIENCE_TYPE)

      described_class.new.perform(@post.id, 3.hours.ago.iso8601)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id,
        nil,
        @product_affiliate.created_at.iso8601
      ).at(@product_affiliate.created_at + @post_rule.delayed_delivery_time)
    end

    it "keeps workflow date filters on the affiliate identity" do
      @post.update!(created_after: 3.days.ago.to_date.iso8601)

      described_class.new.perform(@post.id)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
    end

    it "loads product assignments in bounded queries" do
      second_affiliate = create(:direct_affiliate, seller: @seller, send_posts: true)
      third_affiliate = create(:direct_affiliate, seller: @seller, send_posts: true)
      create(:product_affiliate, affiliate: second_affiliate, product: @product)
      create(:product_affiliate, affiliate: third_affiliate, product: @product)
      stub_const("#{described_class}::AFFILIATE_LOOKUP_BATCH_SIZE", 2)
      expect(ProductAffiliate).to receive(:joins).with(:affiliate).twice.and_call_original

      described_class.new.perform(@post.id)

      expect(SendWorkflowInstallmentWorker.jobs.size).to eq(3)
    end

    it "preserves the product assignment time during a reschedule scan" do
      described_class.new.perform(@post.id, nil, true, @post_rule.version)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id,
        nil,
        @product_affiliate.created_at.iso8601
      ).at(@product_affiliate.created_at + @post_rule.delayed_delivery_time)
    end

    it "repairs an affiliate assigned in the publication second" do
      published_at = Time.current.change(usec: 0)
      @post.update!(published_at:, is_for_new_customers_of_workflow: true)
      @product_affiliate.update_columns(created_at: published_at)

      described_class.new.perform(@post.id, published_at.iso8601, true, @post_rule.version)

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id,
        nil,
        published_at.iso8601
      ).at(published_at + @post_rule.delayed_delivery_time)
    end

    it "repairs an affiliate before the old job after a shorter delay edit" do
      old_delay = 7.days
      old_deliver_at = @product_affiliate.created_at + old_delay
      @post_rule.update!(delayed_delivery_time: 1.hour)

      described_class.new.perform(@post.id, (Time.current - old_delay).iso8601, true, @post_rule.version)

      expect(old_deliver_at).to be > Time.current
      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id,
        nil,
        @product_affiliate.created_at.iso8601
      ).immediately
    end
  end

  describe "#perform with a purchase reschedule" do
    before do
      @product = create(:product, user: @seller, price_cents: 0)
      @post.update!(
        installment_type: Installment::PRODUCT_TYPE,
        link: @product,
        bought_products: [@product.unique_permalink]
      )
    end

    it "preserves the purchase trigger time" do
      purchase = create(:free_purchase, link: @product, created_at: 2.hours.ago)
      purchase.rebuild_audience_member_details
      reference_time = purchase.created_at.change(usec: 0)

      described_class.new.perform(@post.id, nil, true, @post_rule.version)

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        purchase.id,
        nil,
        nil,
        nil,
        reference_time.iso8601
      ).at(reference_time + @post_rule.delayed_delivery_time)
    end

    it "schedules only the older purchase that matches the product filter" do
      email = "filtered-buyer@example.com"
      matching_purchase = create(:free_purchase, link: @product, email:, created_at: 2.hours.ago)
      matching_purchase.rebuild_audience_member_details
      other_product = create(:product, user: @seller, price_cents: 0)
      nonmatching_purchase = create(:free_purchase, link: other_product, email:, created_at: 1.hour.ago)
      nonmatching_purchase.rebuild_audience_member_details

      member = AudienceMember.filter(
        seller_id: @post.seller_id,
        params: @post.audience_members_filter_params,
        with_ids: true
      ).sole
      expect(member.purchase_id).to eq(matching_purchase.id)

      described_class.new.perform(@post.id, nil, true, @post_rule.version)

      reference_time = matching_purchase.created_at.change(usec: 0)
      expect(SendWorkflowInstallmentRescheduleJob.jobs.size).to eq(1)
      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        matching_purchase.id,
        nil,
        nil,
        nil,
        reference_time.iso8601
      ).at(reference_time + @post_rule.delayed_delivery_time)
    end

    it "does not use an embedded purchase when the aggregate id is nil" do
      other_product = create(:product, user: @seller, price_cents: 0)
      nonmatching_purchase = create(:free_purchase, link: other_product, created_at: 2.hours.ago)
      member = double(
        id: 123,
        purchase_id: nil,
        follower_id: nil,
        affiliate_id: nil,
        details: {
          "purchases" => [
            {
              "id" => nonmatching_purchase.id,
              "created_at" => nonmatching_purchase.created_at.iso8601,
            },
          ],
        }
      )
      allow(AudienceMember).to receive(:filter).and_return(double(select: [member]))
      expect(Rails.logger).to receive(:error).with(/could not resolve a purchase recipient/)

      described_class.new.perform(@post.id, nil, true, @post_rule.version)

      expect(SendWorkflowInstallmentRescheduleJob.jobs).to be_empty
      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
    end

    it "keeps a later configured recipient cutoff" do
      @post.update!(created_after: 1.day.ago.to_date.iso8601)
      purchase = create(:free_purchase, link: @product, created_at: 2.days.ago)
      purchase.rebuild_audience_member_details

      described_class.new.perform(@post.id, 3.days.ago.iso8601, true, @post_rule.version)

      expect(SendWorkflowInstallmentRescheduleJob.jobs).to be_empty
    end

    it "repairs a purchase from the publication second" do
      published_at = Time.current.change(usec: 0)
      @post.update!(published_at:, is_for_new_customers_of_workflow: true)
      purchase = create(:free_purchase, link: @product, created_at: published_at)
      purchase.rebuild_audience_member_details

      described_class.new.perform(@post.id, published_at.iso8601, true, @post_rule.version)

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @post.id,
        @post_rule.version,
        purchase.id,
        nil,
        nil,
        nil,
        published_at.iso8601
      ).at(published_at + @post_rule.delayed_delivery_time)
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
        @affiliate_trigger = @affiliates[0].product_affiliates.max_by(&:created_at)
        @affiliate_trigger_time = @affiliate_trigger.created_at.change(usec: 0)

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
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
          @post.id,
          @post_rule.version,
          nil,
          nil,
          @affiliates[0].affiliate_user_id,
          nil,
          @affiliate_trigger_time.iso8601
        ).at(@affiliate_trigger_time + @post_rule.delayed_delivery_time)
      end

      it "when affiliate_type? is true and a bought-product filter is set, it still resolves the matching affiliate" do
        create(:purchase, link: @products[0], email: @affiliates[0].affiliate_user.email, created_at: 2.hours.ago)
        @post.update!(installment_type: Installment::AFFILIATE_TYPE, affiliate_products: [@products[0].unique_permalink], bought_products: [@products[0].unique_permalink])

        member = AudienceMember.filter(seller_id: @post.seller_id, params: @post.audience_members_filter_params, with_ids: true).sole
        expect(member.affiliate_id).to eq(@affiliates[0].id)

        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
          @post.id,
          @post_rule.version,
          nil,
          nil,
          @affiliates[0].affiliate_user_id,
          nil,
          @affiliate_trigger_time.iso8601
        ).at(@affiliate_trigger_time + @post_rule.delayed_delivery_time)
      end

      it "enqueues an affiliate id the worker can actually resolve to a user" do
        @post.update!(installment_type: Installment::AFFILIATE_TYPE, affiliate_products: [@products[0].unique_permalink])
        described_class.new.perform(@post.id)

        # The worker resolves this argument with User.find_by, so a DirectAffiliate id here
        # lands on whichever unrelated user happens to share that number, or on nobody.
        enqueued_id = SendWorkflowInstallmentWorker.jobs.last["args"][4]
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
        affiliate_id = nil
        allow(member).to receive(:affiliate_id) { affiliate_id }
        allow(member).to receive(:affiliate_id=) { |value| affiliate_id = value }
        allow(AudienceMember).to receive(:filter).and_return(double(select: [member]))

        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
          @post.id,
          @post_rule.version,
          nil,
          nil,
          @affiliates[0].affiliate_user_id,
          nil,
          @affiliate_trigger_time.iso8601
        ).at(@affiliate_trigger_time + @post_rule.delayed_delivery_time)
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
        affiliate_id = nil
        allow(member).to receive(:affiliate_id) { affiliate_id }
        allow(member).to receive(:affiliate_id=) { |value| affiliate_id = value }
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

        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
          @post.id,
          @post_rule.version,
          nil,
          nil,
          @affiliates[0].affiliate_user_id,
          nil,
          @affiliate_trigger_time.iso8601
        ).at(@affiliate_trigger_time + @post_rule.delayed_delivery_time)

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

  describe "one large blast per seller per day" do
    before do
      @product = create(:product, user: @seller, price_cents: 0)
      @post.update!(
        installment_type: Installment::PRODUCT_TYPE,
        link: @product,
        bought_products: [@product.unique_permalink]
      )
      @post_rule.update!(delayed_delivery_time: 0)
      stub_const("SellerLargeBlastQuota::DEFAULT_THRESHOLD", 3)
      4.times do |i|
        purchase = create(:free_purchase, link: @product, email: "daily-buyer-#{i}@example.com", created_at: 1.hour.ago)
        purchase.rebuild_audience_member_details
      end
    end

    after { $redis.del(RedisKey.seller_large_blast_quota(@seller.id, Date.current)) }

    it "fans out the first large post and holds the next one until tomorrow" do
      second_post = create(:installment, :published, seller: @seller, link: @product, workflow: @workflow,
                                                     installment_type: Installment::PRODUCT_TYPE,
                                                     bought_products: [@product.unique_permalink])
      create(:post_rule, installment: second_post, delayed_delivery_time: 0)

      described_class.new.perform(@post.id)
      expect(SendWorkflowInstallmentWorker.jobs.size).to eq(4)

      SendWorkflowInstallmentWorker.jobs.clear
      described_class.jobs.clear
      described_class.new.perform(second_post.id)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
      expect(described_class).to have_enqueued_sidekiq_job(
        second_post.id, nil, false, nil, nil, nil
      ).at(Time.zone.tomorrow.beginning_of_day)
    end

    it "does not consume the day for a small audience" do
      stub_const("SellerLargeBlastQuota::DEFAULT_THRESHOLD", 100)

      described_class.new.perform(@post.id)

      expect(SendWorkflowInstallmentWorker.jobs.size).to eq(4)
      expect($redis.get(RedisKey.seller_large_blast_quota(@seller.id, Date.current))).to be_nil
    end
  end

  describe "seller fanout lock" do
    before do
      @product = create(:product, user: @seller, price_cents: 0)
      @post.update!(
        installment_type: Installment::PRODUCT_TYPE,
        link: @product,
        bought_products: [@product.unique_permalink]
      )
      purchase = create(:free_purchase, link: @product, created_at: 2.days.ago)
      purchase.rebuild_audience_member_details
    end

    it "requeues when another fanout for the seller is running" do
      $redis.set(RedisKey.workflow_seller_fanout_lock(@seller.id), "held", nx: true, ex: 60)

      described_class.new.perform(@post.id)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
      expect(described_class).to have_enqueued_sidekiq_job(
        @post.id, nil, false, nil, nil, nil
      ).in(30.seconds)
    end

    it "requeues when the seller lock cannot be renewed before any recipient is enqueued" do
      described_class.jobs.clear
      allow_any_instance_of(WorkflowSellerFanoutLock).to receive(:renew).and_return(false)

      described_class.new.perform(@post.id)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
      expect(described_class).to have_enqueued_sidekiq_job(
        @post.id, nil, false, nil, nil, nil
      ).in(30.seconds)
    end

    it "releases the seller lock after a successful fanout" do
      described_class.new.perform(@post.id)

      expect($redis.get(RedisKey.workflow_seller_fanout_lock(@seller.id))).to be_nil
      expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
    end

    it "lets a second post fan out after the first releases the seller lock" do
      second_post = create(:installment, :published, seller: @seller, link: @product, workflow: @workflow,
                                                     installment_type: Installment::PRODUCT_TYPE,
                                                     bought_products: [@product.unique_permalink])
      create(:post_rule, installment: second_post, delayed_delivery_time: 1.day)

      described_class.new.perform(@post.id)
      SendWorkflowInstallmentWorker.jobs.clear
      described_class.new.perform(second_post.id)

      expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
    end
  end

  describe "immediate fanout pacing" do
    before do
      @product = create(:product, user: @seller, price_cents: 0)
      @post.update!(
        installment_type: Installment::PRODUCT_TYPE,
        link: @product,
        bought_products: [@product.unique_permalink]
      )
      @post_rule.update!(delayed_delivery_time: 0)
      stub_const("#{described_class}::IMMEDIATE_FANOUT_THRESHOLD", 3)
      stub_const("#{described_class}::DEFAULT_IMMEDIATE_ENQUEUE_PER_SECOND", 2)
      @paced_purchases = []
      4.times do |i|
        purchase = create(:free_purchase, link: @product, email: "paced-buyer-#{i}@example.com", created_at: 1.hour.ago)
        @paced_purchases << purchase
        purchase.rebuild_audience_member_details
      end
    end

    it "spreads due-now jobs across the paced window" do
      described_class.new.perform(@post.id)

      jobs = SendWorkflowInstallmentWorker.jobs
      expect(jobs.size).to eq(4)
      ats = jobs.filter_map { _1["at"] }.sort
      expect(ats.size).to eq(3)
      expect(ats.last - Time.current.to_f).to be_within(0.05).of(1.5)
    end

    it "keeps oversized due-now fanouts inside the window without a terminal burst" do
      $redis.set(RedisKey.workflow_immediate_fanout_max_spread_seconds, 1)

      described_class.new.perform(@post.id)

      jobs = SendWorkflowInstallmentWorker.jobs
      expect(jobs.size).to eq(4)
      ats = jobs.filter_map { _1["at"] }.sort
      expect(ats.size).to eq(3)
      expect(ats.last - Time.current.to_f).to be_between(0.6, 1.0)
      expect(ats.last - ats[-2]).to be > 0.1
    ensure
      $redis.del(RedisKey.workflow_immediate_fanout_max_spread_seconds)
    end

    it "sizes the pacing rate from due-now recipients, not future recipients" do
      $redis.set(RedisKey.workflow_immediate_fanout_max_spread_seconds, 1)
      @paced_purchases.last.update!(created_at: 1.day.from_now)
      @paced_purchases.last.rebuild_audience_member_details

      described_class.new.perform(@post.id)

      ats = SendWorkflowInstallmentWorker.jobs.filter_map { _1["at"] }.sort
      due_now_ats = ats.select { _1 < 1.hour.from_now.to_f }
      expect(due_now_ats.size).to eq(2)
      expect(due_now_ats.last - Time.current.to_f).to be_between(0.6, 0.8)
      expect(ats.last).to be_within(1).of(1.day.from_now.to_f)
    ensure
      $redis.del(RedisKey.workflow_immediate_fanout_max_spread_seconds)
    end

    it "keeps future deliveries on their original schedule" do
      @post_rule.update!(delayed_delivery_time: 3.days)
      SendWorkflowInstallmentWorker.jobs.clear

      described_class.new.perform(@post.id)

      expected_at = 1.hour.ago + 3.days
      expect(SendWorkflowInstallmentWorker.jobs.size).to eq(4)
      SendWorkflowInstallmentWorker.jobs.each do |job|
        expect(job["at"]).to be_within(1).of(expected_at.to_f)
      end
    end
  end
end
