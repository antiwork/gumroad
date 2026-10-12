# frozen_string_literal: true

describe SyncStripeBusinessProfileUrlJob do
  let(:user) { create(:user, username: "davidsbuild") }
  let!(:merchant_account) { create(:merchant_account, user:, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}") }
  let(:stripe_url) { "#{PROTOCOL}://#{Subdomain.from_username("antdavidson")}/l/client-report-kit" }

  before do
    allow(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id)
      .and_return(double(business_profile: double(url: stripe_url)))
    allow(Stripe::Account).to receive(:update)
  end

  it "rewrites the old subdomain host and keeps the path" do
    described_class.new.perform(user.id, "antdavidson")

    expect(Stripe::Account).to have_received(:update).with(
      merchant_account.charge_processor_merchant_id,
      business_profile: { url: "#{user.subdomain_with_protocol}/l/client-report-kit" }
    )
  end

  context "when the Stripe URL is not on the old subdomain" do
    let(:stripe_url) { "https://example.com/shop" }

    it "does not update the account" do
      described_class.new.perform(user.id, "antdavidson")

      expect(Stripe::Account).not_to have_received(:update)
    end
  end

  context "when the Stripe URL is blank" do
    let(:stripe_url) { nil }

    it "does not update the account" do
      described_class.new.perform(user.id, "antdavidson")

      expect(Stripe::Account).not_to have_received(:update)
    end
  end

  it "does nothing without a Stripe account" do
    merchant_account.destroy!

    described_class.new.perform(user.id, "antdavidson")

    expect(Stripe::Account).not_to have_received(:retrieve)
  end
end
