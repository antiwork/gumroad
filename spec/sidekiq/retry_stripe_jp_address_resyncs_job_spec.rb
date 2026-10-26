# frozen_string_literal: true

require "spec_helper"

describe RetryStripeJpAddressResyncsJob do
  def add_request(user, field_needed, json: {})
    request = user.user_compliance_info_requests.build(field_needed:)
    json.each { |key, value| request.json_data[key.to_s] = value }
    request.save!
    request
  end

  it "enqueues a resync for a seller with an open JP town request" do
    user = create(:user)
    add_request(user, "individual.address_kanji.town")
    add_request(user, "individual.address_kana.town")

    described_class.new.perform

    expect(RetryStripeJpAddressResyncForSellerJob.jobs.size).to eq(1)
    expect(RetryStripeJpAddressResyncForSellerJob).to have_enqueued_sidekiq_job(user.id)
  end

  it "ignores provided requests and other fields" do
    user = create(:user)
    add_request(user, "individual.address_kanji.town").mark_provided!
    add_request(user, "street_address")

    described_class.new.perform

    expect(RetryStripeJpAddressResyncForSellerJob.jobs.size).to eq(0)
  end

  it "waits out the retry interval and stops after the attempt cap" do
    recent = create(:user)
    add_request(recent, "individual.address_kanji.town", json: { address_resync_count: 1, address_resync_at: 1.day.ago.iso8601 })
    capped = create(:user)
    add_request(capped, "individual.address_kanji.town", json: { address_resync_count: described_class::MAX_ATTEMPTS, address_resync_at: 30.days.ago.iso8601 })
    due = create(:user)
    add_request(due, "individual.address_kanji.town", json: { address_resync_count: 1, address_resync_at: 8.days.ago.iso8601 })

    described_class.new.perform

    expect(RetryStripeJpAddressResyncForSellerJob.jobs.map { |job| job["args"] }).to eq([[due.id]])
  end

  it "runs from the weekly payout-setup retry sweep" do
    user = create(:user)
    add_request(user, "individual.address_kana.town")

    RetryStripeRejectedPayoutSetupsJob.new.perform

    expect(RetryStripeJpAddressResyncForSellerJob).to have_enqueued_sidekiq_job(user.id)
  end
end
