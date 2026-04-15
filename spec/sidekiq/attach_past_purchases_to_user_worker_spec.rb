# frozen_string_literal: true

require "spec_helper"

describe AttachPastPurchasesToUserWorker do
  describe "#perform" do
    it "attaches unlinked purchases matching the user's email" do
      user = create(:user)
      purchase1 = create(:purchase, email: user.email, purchaser: nil)
      purchase2 = create(:purchase, email: user.email, purchaser: nil)
      purchase_already_linked = create(:purchase, email: user.email, purchaser: create(:user))

      described_class.new.perform(user.id)

      expect(purchase1.reload.purchaser).to eq(user)
      expect(purchase2.reload.purchaser).to eq(user)
      expect(purchase_already_linked.reload.purchaser).not_to eq(user)
    end

    it "does nothing when user has a blank email" do
      user = create(:user)
      user.update_column(:email, "")

      expect { described_class.new.perform(user.id) }.not_to raise_error
    end

    it "does nothing when there are no unlinked purchases" do
      user = create(:user)

      expect { described_class.new.perform(user.id) }.not_to raise_error
    end
  end
end
