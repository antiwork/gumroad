# frozen_string_literal: true

require "spec_helper"

describe User do
  describe "#disable_buyer_local_currency" do
    it "reads and writes the creator opt-out attribute" do
      seller = create(:user, disable_buyer_local_currency: true)

      expect(seller.disable_buyer_local_currency).to eq(true)

      seller.update!(disable_buyer_local_currency: false)

      expect(seller.reload.disable_buyer_local_currency).to eq(false)
    end

    it "defaults to false so the feature is on by default" do
      expect(create(:user).disable_buyer_local_currency).to eq(false)
    end
  end
end
