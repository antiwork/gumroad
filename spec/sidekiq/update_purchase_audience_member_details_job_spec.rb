# frozen_string_literal: true

require "spec_helper"

describe UpdatePurchaseAudienceMemberDetailsJob do
  describe "#perform" do
    let(:purchase) { create(:purchase, :with_license) }

    it "refreshes the buyer's audience member details for the purchase" do
      purchase.license.update_columns(uses: 7)

      described_class.new.perform(purchase.id)

      member = AudienceMember.find_by(email: purchase.email, seller: purchase.seller)
      details = member.details["purchases"].find { _1["id"] == purchase.id }
      expect(details["license_uses"]).to eq(7)
    end

    it "does not write an audience member for a purchase that no longer qualifies" do
      purchase.update!(can_contact: false)
      AudienceMember.where(email: purchase.email, seller: purchase.seller).destroy_all

      described_class.new.perform(purchase.id)

      expect(AudienceMember.find_by(email: purchase.email, seller: purchase.seller)).to be_nil
    end

    it "raises when the purchase cannot be found so the job retries" do
      # Purchases are soft-deleted, so a genuinely missing row means we read a lagging
      # replica. Raising hands it to Sidekiq's retries rather than dropping the update.
      expect { described_class.new.perform(Purchase.maximum(:id).to_i + 1) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
