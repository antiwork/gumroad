# frozen_string_literal: true

# TODO: Remove this when the new checkout experience is rolled out
module PayWorkflowHelpers
  def fill_cc_details(card_number: "4242424242424242", card_expiry: StripePaymentMethodHelper::EXPIRY_MMYY, card_cvc: "123", zip_code: nil)
    within_fieldset "Card information" do
      within_frame(0) do
        fill_in "Card number", with: card_number, visible: false
        fill_in "MM / YY", with: card_expiry, visible: false
        fill_in "CVC", with: card_cvc, visible: false
        fill_in "ZIP", with: zip_code, visible: false if zip_code.present?
      end
    end
    fill_in "Name on card", with: "Edgar Gumroad"
  end
end
