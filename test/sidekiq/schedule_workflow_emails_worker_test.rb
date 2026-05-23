# frozen_string_literal: true

require "test_helper"

class ScheduleWorkflowEmailsWorkerTest < ActiveSupport::TestCase
  self.described_class = ScheduleWorkflowEmailsWorker


  context_ ScheduleWorkflowEmailsWorker do
    before do
      @product = create(:product)
      @workflow = create(:workflow, seller: @product.user, link: @product)
      @installment = create(:installment, link: @product, workflow: @workflow, published_at: Time.current)
      create(:installment_rule, installment: @installment, delayed_delivery_time: 1.day)
      @purchase = create(:purchase, link: @product, created_at: 1.week.ago, price_cents: 100)
    end

  context_ "#perform" do
  test "enqueues SendWorkflowInstallmentWorker for the installment" do
        described_class.new.perform(@purchase.id)

        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@installment.id, 1, @purchase.id, nil, nil)
      end

  context_ "filters" do
  test "skips workflow if purchase created before" do
          @workflow.created_after = Time.current
          @workflow.save!

          described_class.new.perform(@purchase.id)

          expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
        end

  test "skips workflow if purchase created after" do
          @workflow.created_before = 1.month.ago
          @workflow.save!

          described_class.new.perform(@purchase.id)

          expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
        end

  test "skips workflow if purchase price is too low" do
          @workflow.paid_more_than_cents = 1000
          @workflow.save!

          described_class.new.perform(@purchase.id)

          expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
        end

  test "skips workflow if purchase price is too high" do
          @workflow.paid_less_than_cents = 99
          @workflow.save!

          described_class.new.perform(@purchase.id)

          expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
        end

  test "skips workflow if purchase is for different product" do
          @workflow.bought_products = ["abc"]
          @workflow.save!

          described_class.new.perform(@purchase.id)

          expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
        end

  test "skips workflow if purchase is for different variant" do
          product = create(:product)
          variant = create(:variant, variant_category: create(:variant_category, link: product))
          workflow = create(:seller_workflow, seller: product.user, created_at: Time.current)
          workflow.bought_variants = ["xyz"]
          workflow.save!
          installment = create(:installment, workflow:, published_at: Time.current)
          create(:installment_rule, installment:, delayed_delivery_time: 1.day)
          purchase = create(:purchase, link: product, created_at: 1.week.ago, price_cents: 100)
          purchase.variant_attributes << variant

          described_class.new.perform(purchase.id)

          expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
        end

  test "skips workflow if purchase bought from a different country" do
          @workflow.bought_from = "Canada"
          @workflow.save!

          described_class.new.perform(@purchase.id)

          expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
        end

  test "passes the filters and queues the installment" do
          @workflow.paid_more_than_cents = 10
          @workflow.created_before = Time.current
          @workflow.save!

          described_class.new.perform(@purchase.id)

          expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@installment.id, 1, @purchase.id, nil, nil)
        end
      end
    end
  end
end
