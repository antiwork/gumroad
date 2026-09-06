# frozen_string_literal: true

require "spec_helper"

describe BackfillMerchantAccountRecommendationEligibilityJob do
  it "uses a finite uniqueness lock for the manually started scan" do
    expect(described_class.sidekiq_options).to include(
      "lock" => :until_executed,
      "lock_ttl" => 6.hours.to_i
    )
  end

  it "refreshes each seller with a historically disconnected PayPal or Stripe Connect account" do
    paypal_seller = create(:user)
    stripe_seller = create(:user)
    inactive_paypal_seller = create(:user)
    malformed_stripe_seller = create(:user)
    managed_stripe_seller = create(:user)
    nil_json_stripe_seller = create(:user)
    create(
      :merchant_account_paypal,
      user: paypal_seller,
      deleted_at: 1.day.ago,
      charge_processor_deleted_at: 1.day.ago,
      charge_processor_alive_at: nil
    )
    create(
      :merchant_account_stripe_connect,
      user: stripe_seller,
      deleted_at: 1.day.ago,
      charge_processor_deleted_at: 1.day.ago,
      charge_processor_alive_at: nil
    )
    create(
      :merchant_account_paypal,
      user: paypal_seller,
      deleted_at: 2.days.ago,
      charge_processor_deleted_at: 2.days.ago,
      charge_processor_alive_at: nil
    )
    create(
      :merchant_account_paypal,
      user: inactive_paypal_seller,
      deleted_at: nil,
      charge_processor_deleted_at: nil,
      charge_processor_alive_at: nil
    )
    create(:merchant_account, user: managed_stripe_seller, deleted_at: 1.day.ago, charge_processor_deleted_at: 1.day.ago)
    create(
      :merchant_account,
      user: nil_json_stripe_seller,
      json_data: nil,
      deleted_at: 1.day.ago,
      charge_processor_deleted_at: 1.day.ago
    )
    malformed_stripe = create(
      :merchant_account,
      user: malformed_stripe_seller,
      deleted_at: 1.day.ago,
      charge_processor_deleted_at: 1.day.ago
    )
    malformed_stripe.update_column(:json_data, '"not a hash"')
    create(:merchant_account_paypal, user: create(:user))
    RefreshMerchantAccountProductsRecommendationEligibilityJob.jobs.clear

    described_class.new.perform

    queued_args = RefreshMerchantAccountProductsRecommendationEligibilityJob.jobs.map { |job| job.fetch("args") }
    expect(queued_args).to include(
      [paypal_seller.id],
      [stripe_seller.id],
      [inactive_paypal_seller.id],
      [malformed_stripe_seller.id]
    )
    expect(queued_args.count([paypal_seller.id])).to eq(1)
    expect(queued_args).not_to include([managed_stripe_seller.id])
    expect(queued_args).not_to include([nil_json_stripe_seller.id])
  end

  it "processes every batch within one locked run" do
    accounts = Array.new(3) do
      create(
        :merchant_account_paypal,
        user: create(:user),
        deleted_at: 1.day.ago,
        charge_processor_deleted_at: 1.day.ago,
        charge_processor_alive_at: nil
      )
    end
    stub_const("#{described_class}::BATCH_SIZE", 2)
    job = described_class.new
    allow(job).to receive(:disconnected_accounts).and_return(MerchantAccount.where(id: accounts.map(&:id)))
    RefreshMerchantAccountProductsRecommendationEligibilityJob.jobs.clear

    job.perform

    expect(RefreshMerchantAccountProductsRecommendationEligibilityJob.jobs.map { |queued_job| queued_job.fetch("args") }).to match_array(
      accounts.map { |account| [account.user_id] }
    )
  end
end
