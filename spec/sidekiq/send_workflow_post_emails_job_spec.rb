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
      @basic_follower = create(:active_follower, user: @seller, created_at: 2.day.ago)
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

    it "only considers audience members created after the earliest_valid_time" do
      described_class.new.perform(@post.id, 1.day.ago.iso8601)
      expect(SendWorkflowInstallmentWorker.jobs).to be_empty

      described_class.new.perform(@post.id, 3.days.ago.iso8601)
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, @basic_follower.id, nil)

      # does not limit when earliest_valid_time is nil
      SendWorkflowInstallmentWorker.jobs.clear
      described_class.new.perform(@post.id, nil)
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, @basic_follower.id, nil)
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
        @followers << create(:active_follower, user: @seller, created_at: 5.days.ago)
        @followers << create(:active_follower, user: @seller, email: @sales[0].email, created_at: 5.hours.ago)

        @affiliates = []
        @affiliates << create(:direct_affiliate, seller: @seller, send_posts: true, created_at: 4.hours.ago)
        @affiliates[0].products << @products[0]
        @affiliates[0].products << @products[1]

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
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, @followers[0].id, nil).immediately
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, @followers[1].id, nil).at(19.hours.from_now)
      end

      it "when affiliate_type? is true, it sends the expected emails at the right times" do
        @post.update!(installment_type: Installment::AFFILIATE_TYPE, affiliate_products: [@products[0].unique_permalink])
        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, nil, @affiliates[0].id).at(20.hours.from_now)
      end

      it "when audience_type? is true, it sends the expected emails at the right times" do
        described_class.new.perform(@post.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(7)

        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, @followers[0].id, nil).immediately
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, @followers[1].id, nil).at(19.hours.from_now)

        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, nil, nil, @affiliates[0].id).at(20.hours.from_now)

        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[2].id, nil, nil).immediately
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[3].id, nil, nil).immediately
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[4].id, nil, nil).immediately
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@post.id, @post_rule.version, @sales[5].id, nil, nil).at(18.hours.from_now)
      end
    end
  end
end
