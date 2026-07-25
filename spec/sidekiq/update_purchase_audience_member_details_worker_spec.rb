# frozen_string_literal: true

require "spec_helper"

describe UpdatePurchaseAudienceMemberDetailsWorker do
  describe "#perform" do
    let(:purchase) { create(:purchase, :with_license) }

    it "refreshes the buyer's audience member details for the purchase" do
      purchase.license.update_columns(uses: 7)

      described_class.new.perform(purchase.id)

      member = AudienceMember.find_by(email: purchase.email, seller: purchase.seller)
      details = member.details["purchases"].find { _1["id"] == purchase.id }
      expect(details["license_uses"]).to eq(7)
    end

    it "does nothing when the purchase no longer exists" do
      missing_id = purchase.id
      purchase.destroy!

      expect { described_class.new.perform(missing_id) }.not_to raise_error
    end
  end
end
