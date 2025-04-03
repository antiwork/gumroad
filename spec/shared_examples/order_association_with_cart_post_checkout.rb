# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "order association with cart post checkout" do
  let!(:user_cart) { create(:cart, user:, browser_guid:) }
  let!(:guest_cart) { create(:cart, :guest, browser_guid:) }

  context "when the user is signed in" do
    before do
      sign_in_user_action
    end

    it "associates the order with the user cart and deletes it" do
      expect do
        call_action
      end.to change { Order.count }.from(0).to(1)
      expect(user_cart.reload.order).to eq(Order.last)
      expect(user_cart).to be_deleted
      expect(guest_cart.reload.order).to be_nil
      expect(guest_cart).to be_alive
    end
  end

  context "when the user is not logged in" do
    it "associates the order with the guest cart and deletes it" do
      expect do
        call_action
      end.to change { Order.count }.from(0).to(1)
      expect(guest_cart.reload.order).to eq(Order.last)
      expect(guest_cart).to be_deleted
      expect(user_cart.reload.order).to be_nil
      expect(user_cart).to be_alive
    end
  end
end
