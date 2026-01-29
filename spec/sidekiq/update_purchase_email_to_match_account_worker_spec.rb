# frozen_string_literal: true

require "spec_helper"

describe UpdatePurchaseEmailToMatchAccountWorker do
  before do
    @user = create(:user)
    @purchase_a = create(:purchase, email: "old@gmail.com", purchaser: @user)
    @purchase_b = create(:purchase, email: @user.email, purchaser: @user)
  end

  describe "#perform" do
    it "updates email address in every purchased product" do
      described_class.new.perform(@user.id)

      expect(@user.reload.purchases.size).to eq 2
      expect(@purchase_a.reload.email).to eq @user.email
      expect(@purchase_b.reload.email).to eq @user.email
    end

    it "updates gift purchases with null purchaser_id when old_email is provided" do
      old_email = "old@gmail.com"
      gift_purchase = create(:purchase, email: old_email, is_gift_receiver_purchase: true, purchaser: nil)
      gift_purchase.update_columns(purchaser_id: nil)

      described_class.new.perform(@user.id, old_email)

      expect(gift_purchase.reload.email).to eq @user.email
    end

    it "does not update gift purchases when old_email is not provided" do
      old_email = "old@gmail.com"
      gift_purchase = create(:purchase, email: old_email, is_gift_receiver_purchase: true, purchaser: nil)
      gift_purchase.update_columns(purchaser_id: nil)

      described_class.new.perform(@user.id)

      expect(gift_purchase.reload.email).to eq old_email
    end
  end
end
