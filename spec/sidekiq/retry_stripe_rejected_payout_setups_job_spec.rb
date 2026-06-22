# frozen_string_literal: true

require "spec_helper"

describe RetryStripeRejectedPayoutSetupsJob do
  let(:bank_prefix) { StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX }
  let(:postal_prefix) { StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX }

  def failure_note(user, prefix, json: {})
    note = user.add_payout_note(content: "#{prefix}: some_code — some message")
    json.each { |key, value| note.json_data[key.to_s] = value }
    note.save!
    note
  end

  it "enqueues a per-seller retry for a fresh bank sync failure note" do
    user = create(:user)
    failure_note(user, bank_prefix)

    described_class.new.perform

    expect(RetryStripeRejectedPayoutSetupForSellerJob).to have_enqueued_sidekiq_job(user.id)
  end

  it "enqueues a per-seller retry for a fresh postal code rejection note" do
    user = create(:user)
    failure_note(user, postal_prefix)

    described_class.new.perform

    expect(RetryStripeRejectedPayoutSetupForSellerJob).to have_enqueued_sidekiq_job(user.id)
  end

  it "skips abandoned notes" do
    user = create(:user)
    failure_note(user, bank_prefix, json: { abandoned_at: Time.current.iso8601 })

    described_class.new.perform

    expect(RetryStripeRejectedPayoutSetupForSellerJob.jobs.size).to eq(0)
  end

  it "skips notes whose backoff window has not elapsed" do
    user = create(:user)
    failure_note(user, bank_prefix, json: { retry_count: 1, last_retried_at: (described_class::RETRY_INTERVAL_DAYS - 1).days.ago.iso8601 })

    described_class.new.perform

    expect(RetryStripeRejectedPayoutSetupForSellerJob.jobs.size).to eq(0)
  end

  it "enqueues notes whose backoff window has elapsed" do
    user = create(:user)
    failure_note(user, bank_prefix, json: { retry_count: 1, last_retried_at: (described_class::RETRY_INTERVAL_DAYS + 1).days.ago.iso8601 })

    described_class.new.perform

    expect(RetryStripeRejectedPayoutSetupForSellerJob).to have_enqueued_sidekiq_job(user.id)
  end

  it "enqueues exhausted notes so the per-seller job can give up" do
    user = create(:user)
    failure_note(user, bank_prefix, json: { retry_count: described_class::MAX_RETRIES, last_retried_at: Time.current.iso8601 })

    described_class.new.perform

    expect(RetryStripeRejectedPayoutSetupForSellerJob).to have_enqueued_sidekiq_job(user.id)
  end

  it "deduplicates multiple outstanding notes for the same seller" do
    user = create(:user)
    failure_note(user, bank_prefix)
    failure_note(user, postal_prefix)

    described_class.new.perform

    expect(RetryStripeRejectedPayoutSetupForSellerJob.jobs.size).to eq(1)
  end

  it "ignores unrelated payout notes" do
    user = create(:user)
    user.add_payout_note(content: "Scheduled payouts paused on May 1, 2026")

    described_class.new.perform

    expect(RetryStripeRejectedPayoutSetupForSellerJob.jobs.size).to eq(0)
  end

  it "ignores deleted failure notes" do
    user = create(:user)
    failure_note(user, bank_prefix).mark_deleted!

    described_class.new.perform

    expect(RetryStripeRejectedPayoutSetupForSellerJob.jobs.size).to eq(0)
  end
end
