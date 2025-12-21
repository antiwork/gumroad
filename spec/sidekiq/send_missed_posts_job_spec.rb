# frozen_string_literal: true

require "spec_helper"

describe SendMissedPostsJob do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, seller:, link: product) }
  let(:customer_dnd_enabled_error_message) { "Purchase #{purchase.id} has opted out of receiving emails" }
  let(:seller_not_eligible_error_message) { "You are not eligible to resend this email." }

  describe "#perform" do
    it "finds purchase by external ID and calls service" do
      expect(CustomersService).to receive(:deliver_missed_posts_for!).with(purchase:, workflow_id: nil)

      described_class.new.perform(purchase.external_id)
    end

    it "raises error when purchase is not found" do
      expect do
        described_class.new.perform("invalid_external_id")
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises CustomerDNDEnabledError" do
      create(:payment_completed, user: seller)
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
      create(:installment, link: product, seller:, published_at: 1.day.ago)
      purchase.update!(can_contact: false)

      expect do
        described_class.new.perform(purchase.external_id)
      end.to raise_error(CustomersService::CustomerDNDEnabledError, customer_dnd_enabled_error_message)
    end

    it "raises SellerNotEligibleError" do
      create(:installment, link: product, seller:, published_at: 1.day.ago)
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)

      expect do
        described_class.new.perform(purchase.external_id)
      end.to raise_error(CustomersService::SellerNotEligibleError, seller_not_eligible_error_message)
    end
  end

  describe "sidekiq_retry_in" do
    it "returns :discard and logs for CustomerDNDEnabledError" do
      exception = CustomersService::CustomerDNDEnabledError.new(customer_dnd_enabled_error_message)

      expect(Rails.logger).to receive(:info)
        .with("[SendMissedPostsJob] Discarding job on 1st attempt for purchase with DND enabled: #{customer_dnd_enabled_error_message}")

      result = described_class::RetryHandler.call(0, exception, {})
      expect(result).to eq(:discard)
    end

    it "returns :discard and logs for SellerNotEligibleError" do
      exception = CustomersService::SellerNotEligibleError.new(seller_not_eligible_error_message)

      expect(Rails.logger).to receive(:info)
        .with("[SendMissedPostsJob] Discarding job on 1st attempt for ineligible seller: #{seller_not_eligible_error_message}")

      result = described_class::RetryHandler.call(0, exception, {})
      expect(result).to eq(:discard)
    end

    it "returns nil for other exceptions to allow normal retry" do
      other_exception = StandardError.new("Some error")
      result = described_class::RetryHandler.call(0, other_exception, {})
      expect(result).to be_nil
    end
  end

  describe "sidekiq_retries_exhausted" do
    let(:job_info) { { "class" => "SendMissedPostsJob", "args" => [purchase.external_id, nil] } }

    it "broadcasts failure message when retries are exhausted" do
      expect(CustomersChannel).to receive(:broadcast_missed_posts_message!).with(
        purchase.external_id,
        nil,
        CustomersChannel::MISSED_POSTS_JOB_FAILED_TYPE
      )

      described_class::FailureHandler.call(job_info, StandardError.new("Test error"))
    end

    it "includes workflow name in failure message when workflow_id is provided" do
      workflow = create(:workflow, seller: seller, name: "My Workflow")
      job_info = { "class" => "SendMissedPostsJob", "args" => [purchase.external_id, workflow.external_id] }

      expect(CustomersChannel).to receive(:broadcast_missed_posts_message!).with(
        purchase.external_id,
        workflow.external_id,
        CustomersChannel::MISSED_POSTS_JOB_FAILED_TYPE
      )

      described_class::FailureHandler.call(job_info, StandardError.new("Test error"))
    end

    it "raises error when purchase is not found" do
      job_info = { "class" => "SendMissedPostsJob", "args" => ["invalid_external_id", nil] }

      expect(CustomersChannel).to receive(:broadcast_missed_posts_message!).and_call_original

      expect do
        described_class::FailureHandler.call(job_info, StandardError.new("Test error"))
      end.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
