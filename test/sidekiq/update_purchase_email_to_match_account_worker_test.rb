# frozen_string_literal: true

require "test_helper"

class UpdatePurchaseEmailToMatchAccountWorkerTest < ActiveSupport::TestCase
  self.described_class = UpdatePurchaseEmailToMatchAccountWorker



  context_ UpdatePurchaseEmailToMatchAccountWorker do
    before do
      @user = create(:user)
      @purchase_a = create(:purchase, email: "old@gmail.com", purchaser: @user)
      @purchase_b = create(:purchase, email: @user.email, purchaser: @user)
    end

  context_ "#perform" do
  test "updates email address in every purchased product" do
        described_class.new.perform(@user.id)

        expect(@user.reload.purchases.size).to eq 2
        expect(@purchase_a.reload.email).to eq @user.email
        expect(@purchase_b.reload.email).to eq @user.email
      end
    end
  end
end
