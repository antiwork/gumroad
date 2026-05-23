# frozen_string_literal: true

require "test_helper"

class UserPurchasesTest < ActiveSupport::TestCase
  self.described_class = User::Purchases



  context_ User::Purchases do
  context_ "#transfer_purchases!" do
      let(:user) { create(:user) }
      let(:new_user) { create(:user) }
      let!(:purchases) { create_list(:purchase, 3, email: user.email, purchaser: user) }

  test "transfers purchases to the new user" do
        user.transfer_purchases!(new_email: new_user.email)

        purchases.each do |purchase|
          expect(purchase.reload.email).to eq(new_user.email)
          expect(purchase.reload.purchaser).to eq(new_user)
        end
      end

  test "raises ActiveRecord::RecordNotFound if the new user does not exist" do
        expect do
          user.transfer_purchases!(new_email: Faker::Internet.email)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
