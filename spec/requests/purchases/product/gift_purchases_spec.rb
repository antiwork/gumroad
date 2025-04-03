# frozen_string_literal: true

require("spec_helper")
require "timeout"

describe("Gift purchases from the product page", type: :feature, js: true) do
  before do
    @user = create(:named_user)
    @product = create(:product, user: @user, custom_receipt: "<h1>Hello</h1>")
  end

  describe "gift purchases" do
    let(:giftee_email) { "giftee@gumroad.com" }

    it "allows gift purchase if product can be gifted" do
      visit "/l/#{@product.unique_permalink}"
      add_to_cart(@product)
      check_out(@product, gift: { email: giftee_email, note: "Gifting from product page!" })
      expect(Purchase.all_success_states.count).to eq 2
      expect(Gift.successful.where(link_id: @product.id, gifter_email: "test@gumroad.com", giftee_email:).count).to eq 1
    end

    it "prevents the user from gifting to an invalid giftee address" do
      visit "/l/#{@product.unique_permalink}"
      add_to_cart(@product)
      check_out(@product, gift: { email: "bad", note: "" }, error: true)
      expect(find_field("Recipient email")["aria-invalid"]).to eq("true")
      expect(Purchase.all_success_states.count).to eq 0
      expect(Gift.count).to eq 0

      check_out(@product, gift: { email: giftee_email, note: "" })

      expect(Purchase.all_success_states.count).to eq 2
      expect(Gift.successful.where(link_id: @product.id, gifter_email: "test@gumroad.com", giftee_email:).count).to eq 1
    end
  end
end
