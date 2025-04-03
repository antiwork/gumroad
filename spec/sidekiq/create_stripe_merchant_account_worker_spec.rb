# frozen_string_literal: true

require "spec_helper"

describe CreateStripeMerchantAccountWorker do
  describe "#perform" do
    let(:user) do
      user = create(:user)
      create(:user_compliance_info, user:)
      create(:tos_agreement, user:)
      user
    end

    it "creates an account for the user" do
      expect(StripeMerchantAccountManager).to receive(:create_account).with(user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))

      described_class.new.perform(user.id)
    end

    it "receives Stripe::InvalidRequestError" do
      error_message = "Invalid account number: must contain only digits, and be at most 12 digits long"
      allow(Stripe::Account).to receive(:create).and_raise(Stripe::InvalidRequestError.new(error_message, nil))

      expect do
        described_class.new.perform(user.id)
      end.to raise_error(Stripe::InvalidRequestError)
    end
  end
end
