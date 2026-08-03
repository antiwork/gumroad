# frozen_string_literal: true

require "spec_helper"

# A seller whose Stripe payout setup was rejected has a saved bank account and no rail, so the
# generic "connect a payment method" wall sent them looking for something that was already there —
# one seller stayed blocked for a month (gumroad-private#1777).
describe Link, "#publish! when the seller cannot be paid out" do
  # payment_address is populated by the factory, and it alone satisfies can_publish_products?, so a
  # seller with no payout rail has to be built explicitly.
  let(:seller) { create(:user, payment_address: nil) }
  let(:product) { create(:product, user: seller, draft: true, purchase_disabled_at: Time.current) }

  def publish_error
    product.publish!
    nil
  rescue Link::LinkInvalid => e
    e.message
  end

  it "points at the rejected field when Stripe refused the seller's payout setup" do
    seller.add_payout_note(
      content: "Our payment partner couldn't accept the phone number you entered. For a US individual or sole-proprietorship account it has to be a US number, even if you live elsewhere.",
      seller_visible: true,
      json_data: { StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG => true }
    )

    expect(publish_error).to eq(
      "Your payout setup hasn't gone through yet, so you can't publish this product for sale. " \
      "Our payment partner couldn't accept the phone number you entered. For a US individual or sole-proprietorship account it has to be a US number, even if you live elsewhere."
    )
  end

  it "keeps the generic message for a seller who never started payout setup" do
    expect(publish_error).to eq("You must connect at least one payment method before you can publish this product for sale.")
  end

  # Keyed on the rejection note's own marker: a skipped-payout explanation is the note most sellers
  # have, and reading whichever seller-visible note is newest would blame a rejection that never
  # happened.
  it "keeps the generic message when the newest seller-visible note is an unrelated payout explanation" do
    seller.add_payout_note(content: "Your payout was skipped because your balance was below the minimum.", seller_visible: true)

    expect(publish_error).to eq("You must connect at least one payment method before you can publish this product for sale.")
  end

  it "does not block a seller who has a payout rail, rejection note or not" do
    seller.add_payout_note(
      content: "Our payment partner couldn't accept the Tax ID you entered.",
      seller_visible: true,
      json_data: { StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG => true }
    )
    create(:merchant_account_stripe_connect, user: seller)

    expect(publish_error).to be_nil
    expect(product.reload.published?).to be(true)
  end
end
