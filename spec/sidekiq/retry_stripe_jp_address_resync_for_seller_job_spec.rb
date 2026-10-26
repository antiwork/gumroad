# frozen_string_literal: true

require "spec_helper"

describe RetryStripeJpAddressResyncForSellerJob do
  let(:user) { create(:user, payment_address: nil) }
  let!(:user_compliance_info) { create(:user_compliance_info, user:) }
  let!(:merchant_account) { create(:merchant_account, user:) }
  let!(:request) { user.user_compliance_info_requests.create!(field_needed: "individual.address_kanji.town") }

  it "force-resyncs the address quietly and records the attempt" do
    expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)
      .with(user.alive_user_compliance_info, hash_including(notify: false, force_address_resync: true))

    described_class.new.perform(user.id)

    request.reload
    expect(request).to be_requested
    expect(request.json_data["address_resync_count"]).to eq(1)
    expect(request.json_data["address_resync_at"]).to be_present
  end

  it "counts a failed attempt without raising" do
    allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info).and_raise(Stripe::APIError.new("boom"))

    expect { described_class.new.perform(user.id) }.not_to raise_error

    expect(request.reload.json_data["address_resync_count"]).to eq(1)
  end

  it "does nothing when there is no open JP address request" do
    request.mark_provided!
    expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

    described_class.new.perform(user.id)
  end

  it "skips suspended sellers" do
    allow_any_instance_of(User).to receive(:suspended?).and_return(true)
    expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

    described_class.new.perform(user.id)
  end
end
