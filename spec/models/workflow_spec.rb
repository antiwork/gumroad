# frozen_string_literal: true

require "spec_helper"
require "shared_examples/with_filtering_support"

describe Workflow do
  before do
    @product = create(:product)
    @workflow = create(:workflow, seller: @product.user, link: @product)
    @post = create(:installment, link: @product, workflow: @workflow, published_at: 1.day.ago)
    @post_rule = create(:installment_rule, installment: @post, delayed_delivery_time: 1.day)
    @purchase = create(:purchase, link: @product, created_at: 1.minute.ago, price_cents: 100)
  end

  describe "scopes" do
    describe "published" do
      it "returns only published workflows" do
        published_workflow = create(:workflow, published_at: 1.day.ago)
        expect(Workflow.count).to eq(2)
        expect(Workflow.published).to eq([published_workflow])
      end
    end
  end

  describe "#applies_to_purchase?" do
    context "for a product workflow" do
      let(:workflow) { create(:workflow) }

      it "returns true for a purchase of the workflow product" do
        purchase = create(:purchase, link: workflow.link)
        expect(workflow.applies_to_purchase?(purchase)).to eq true
      end

      it "returns false for a purchase of the workflow product that fails filters" do
        purchase = create(:purchase, link: workflow.link)
        allow(workflow).to receive(:purchase_passes_filters).with(purchase).and_return(false)
        expect(workflow.applies_to_purchase?(purchase)).to eq false
      end

      it "returns false for a purchase of a different product" do
        purchase = create(:purchase)
        expect(workflow.applies_to_purchase?(purchase)).to eq false
      end
    end

    context "for a variant workflow" do
      let(:workflow) { create(:variant_workflow) }

      it "returns true for a purchase of the workflow variant" do
        purchase = create(:purchase, variant_attributes: [workflow.base_variant])
        expect(workflow.applies_to_purchase?(purchase)).to eq true
      end

      it "returns false for a purchase of the workflow variant that fails filters" do
        purchase = create(:purchase, variant_attributes: [workflow.base_variant])
        allow(workflow).to receive(:purchase_passes_filters).with(purchase).and_return(false)
        expect(workflow.applies_to_purchase?(purchase)).to eq false
      end

      it "returns false for a purchase of a different variant" do
        purchase = create(:purchase, variant_attributes: [create(:variant)])
        expect(workflow.applies_to_purchase?(purchase)).to eq false
      end
    end

    context "for a seller workflow" do
      let(:workflow) { create(:seller_workflow) }
      let(:purchase) { create(:purchase) }

      it "returns true for a purchase that passes the workflow filters" do
        allow(workflow).to receive(:purchase_passes_filters).with(purchase).and_return(true)
        expect(workflow.applies_to_purchase?(purchase)).to eq true
      end

      it "returns false for apurchase that fails the workflow filters" do
        allow(workflow).to receive(:purchase_passes_filters).with(purchase).and_return(false)
        expect(workflow.applies_to_purchase?(purchase)).to eq false
      end
    end
  end

  describe "#targets_variant?" do
    context "for a variant workflow" do
      let(:workflow) { create(:variant_workflow) }

      it "returns true if it targets the given variant" do
        expect(workflow.targets_variant?(workflow.base_variant)).to eq true
      end

      it "returns false if it targets a different variant" do
        expect(workflow.targets_variant?(create(:variant))).to eq false
      end
    end

    context "for a workflow with bought_variants set" do
      let(:variant) { create(:variant) }
      let(:workflow) { create(:seller_workflow, bought_variants: [variant.external_id]) }

      it "returns true if it targets the given variant" do
        expect(workflow.targets_variant?(variant)).to eq true
      end

      it "returns false if it does not target the given variant" do
        expect(workflow.targets_variant?(create(:variant))).to eq false
      end
    end

    context "for a non-variant workflow without bought_variants set" do
      it "returns false" do
        workflow = create(:workflow)
        expect(workflow.targets_variant?(create(:variant))).to eq false
      end
    end
  end

  describe "mark_deleted" do
    it "marks workflow and installments as deleted" do
      seller = create(:user)
      link = create(:product, user: seller)
      product_workflow = create(:workflow, seller:, link:)
      seller_workflow = create(:workflow, seller:, link: nil)
      installment1 =  create(:installment, workflow: seller_workflow)
      create(:installment_rule, installment: installment1, delayed_delivery_time: 3.days)
      installment2 = create(:installment, workflow: product_workflow)
      create(:installment_rule, installment: installment2, delayed_delivery_time: 3.days)
      installment3 = create(:installment, workflow: product_workflow)
      create(:installment_rule, installment: installment3, delayed_delivery_time: 1.day)

      product_workflow.mark_deleted!
      expect(product_workflow.reload.deleted_at.present?).to be(true)
      expect(installment2.reload.deleted_at.present?).to be(true)
      expect(installment3.reload.deleted_at.present?).to be(true)
      expect(installment1.reload.deleted_at.present?).to be(false)
      seller_workflow.mark_deleted!
      expect(seller_workflow.reload.deleted_at.present?).to be(true)
      expect(installment1.reload.deleted_at.present?).to be(true)
    end
  end

  describe "#schedule_installment", :freeze_time do
    it "does nothing when the workflow is not published" do
      @workflow.mark_deleted!
      @workflow.schedule_installment(@post)
      expect(SendWorkflowPostEmailsJob.jobs).to be_empty
    end

    it "does nothing when the post is not published" do
      @post.unpublish!
      @workflow.schedule_installment(@post)
      expect(SendWorkflowPostEmailsJob.jobs).to be_empty
    end

    it "does nothing when workflow has a trigger" do
      @workflow.update!(workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER)
      @workflow.schedule_installment(@post)
      expect(SendWorkflowPostEmailsJob.jobs).to be_empty
    end

    it "does nothing if the post is only for new recipients and it hasn't been scheduled before" do
      @post.update!(is_for_new_customers_of_workflow: true)
      @workflow.schedule_installment(@post)
      expect(SendWorkflowPostEmailsJob.jobs).to be_empty
    end

    it "does nothing for an abandoned cart installment" do
      workflow = create(:abandoned_cart_workflow, seller: @workflow.seller, published_at: 1.day.ago)
      installment = workflow.installments.sole
      workflow.schedule_installment(installment)
      expect(SendWorkflowPostEmailsJob.jobs).to be_empty
    end

    context "workflow wasn't previously scheduled" do
      it "enqueues job with earliest_valid_time = nil" do
        @workflow.schedule_installment(@post)
        expect(SendWorkflowPostEmailsJob).to have_enqueued_sidekiq_job(@post.id, nil)
      end
    end

    context "workflow was previously scheduled (old_delayed_delivery_time != nil)" do
      let(:old_delayed_delivery_time) { 6.hours.to_i }

      context "post is for new recipients" do
        before { @post.update!(is_for_new_customers_of_workflow: true) }

        it "enqueues job with earliest_valid_time = post.published_at if the post was published after the old delay" do
          @post.update!(published_at: 1.hour.ago)
          @workflow.schedule_installment(@post, old_delayed_delivery_time:)
          expect(SendWorkflowPostEmailsJob).to have_enqueued_sidekiq_job(@post.id, @post.published_at.iso8601)
        end

        it "enqueues job with earliest_valid_time = old_delayed_delivery_time.seconds.ago if the post was published before the old delay" do
          @post.update!(published_at: 9.hours.ago)
          @workflow.schedule_installment(@post, old_delayed_delivery_time:)
          expect(SendWorkflowPostEmailsJob).to have_enqueued_sidekiq_job(@post.id, old_delayed_delivery_time.seconds.ago.iso8601)
        end
      end

      context "post is not for new recipients" do
        before { @post.update!(is_for_new_customers_of_workflow: false) }

        it "enqueues job with earliest_valid_time = old_delayed_delivery_time.seconds.ago" do
          @workflow.schedule_installment(@post, old_delayed_delivery_time:)
          expect(SendWorkflowPostEmailsJob).to have_enqueued_sidekiq_job(@post.id, old_delayed_delivery_time.seconds.ago.iso8601)
        end
      end
    end
  end

  describe "#add_and_validate_filters" do
    let(:user) { create(:user) }
    let!(:product) { create(:product, user:) }

    subject(:add_and_validate_filters) { filterable_object.add_and_validate_filters(params, user) }

    it_behaves_like "common customer recipient filter validation behavior", audience_type: "product" do
      let(:filterable_object) { create(:product_workflow, seller: user, link: product) }
    end

    it_behaves_like "common customer recipient filter validation behavior", audience_type: "variant" do
      let(:filterable_object) { create(:variant_workflow, seller: user, link: product) }
    end

    it_behaves_like "common customer recipient filter validation behavior", audience_type: "seller" do
      let(:filterable_object) { create(:seller_workflow, seller: user, link: product) }
    end

    it_behaves_like "common non-customer recipient filter validation behavior", audience_type: "audience" do
      let(:filterable_object) { create(:audience_workflow, seller: user, link: product) }
    end

    it_behaves_like "common non-customer recipient filter validation behavior", audience_type: "follower" do
      let(:filterable_object) { create(:follower_workflow, seller: user, link: product) }
    end

    it_behaves_like "common non-customer recipient filter validation behavior", audience_type: "affiliate" do
      let(:filterable_object) { create(:affiliate_workflow, seller: user, link: product) }
    end
  end

  describe "#publish!" do
    before do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
      create(:merchant_account_stripe_connect, user: @workflow.seller)
      create(:payment_completed, user: @workflow.seller)
    end

    it "does nothing if the workflow is already published" do
      @workflow.update!(published_at: 1.day.ago, first_published_at: 2.days.ago)

      expect { @workflow.publish! }.not_to change { @workflow.reload }
    end

    it "sets 'published_at' and 'first_published_at'" do
      expect do
        @workflow.publish!
      end.to change { @workflow.reload.published_at }.from(nil).to(be_within(1.second).of(Time.current))
         .and change { @workflow.reload.first_published_at }.from(nil).to(be_within(1.second).of(Time.current))
    end

    it "does not update 'first_published_at' if it is already set" do
      @workflow.update!(first_published_at: 2.days.ago)

      expect do
        expect do
          @workflow.publish!
        end.to change { @workflow.reload.published_at }.from(nil).to(be_within(1.second).of(Time.current))
      end.not_to change { @workflow.reload.first_published_at }
    end

    it "publishes and schedules all alive installments" do
      installment1 = create(:installment, workflow: @workflow)
      installment2 = create(:installment, workflow: @workflow, deleted_at: 1.day.ago)

      expect(@workflow).to receive(:schedule_installment).with(an_instance_of(Installment)).twice

      expect do
        expect do
          @workflow.publish!
        end.to change { @post.reload.published_at }.from(kind_of(Time)).to(be_within(1.second).of(Time.current))
           .and change { installment1.reload.published_at }.from(nil).to(be_within(1.second).of(Time.current))
      end.not_to change { installment2.reload.published_at }
    end

    it "raises an error if the seller is not eligible to send emails" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)

      installment1 = create(:installment, workflow: @workflow)
      installment2 = create(:installment, workflow: @workflow)

      expect { @workflow.publish! }.to raise_error(ActiveRecord::RecordInvalid, "Validation failed: You cannot publish a workflow until you have made at least $100 in total earnings and received a payout")
      expect(@workflow.reload.published_at).to be_nil
      expect(installment1.reload.published_at).to be_nil
      expect(installment2.reload.published_at).to be_nil
    end
  end

  describe "#unpublish!" do
    it "does nothing if the workflow is already unpublished" do
      expect { @workflow.unpublish! }.not_to change { @workflow.reload }
    end

    it "sets 'published_at' to nil and does not change 'first_published_at'" do
      @workflow.update!(published_at: 1.day.ago, first_published_at: 2.days.ago)

      expect do
        expect do
          @workflow.unpublish!
        end.to change { @workflow.reload.published_at }.from(kind_of(Time)).to(nil)
      end.not_to change { @workflow.reload.first_published_at }
    end

    it "unpublishes all alive installments" do
      @workflow.update!(published_at: 1.day.ago)
      @post.update!(published_at: 1.day.ago)
      installment1 = create(:installment, workflow: @workflow, published_at: 1.day.ago)
      installment2 = create(:installment, workflow: @workflow, published_at: 1.day.ago, deleted_at: 1.hour.ago)

      expect do
        expect do
          @workflow.unpublish!
        end.to change { @post.reload.published_at }.from(kind_of(Time)).to(nil)
           .and change { installment1.reload.published_at }.from(kind_of(Time)).to(nil)
      end.not_to change { installment2.reload.published_at }
    end
  end

  describe "#has_never_been_published?" do
    it "returns true if the workflow has never been published" do
      expect(@workflow.has_never_been_published?).to be(true)
    end

    it "returns false if the workflow has been published before" do
      @workflow.update!(first_published_at: 1.day.ago)

      expect(@workflow.has_never_been_published?).to be(false)
    end
  end
end
