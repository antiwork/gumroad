# frozen_string_literal: true

require "spec_helper"

RSpec.shared_context "when is a preorder authorization" do
  let(:preorder_link) { create(:preorder_link, link: purchase.link, release_at: DateTime.parse("Dec 1 2223 10AM PST")) }

  before do
    preorder = create(:preorder, preorder_link:, seller: product.user, state: "authorization_successful")
    purchase.update!(preorder:, is_preorder_authorization: true)
  end
end

RSpec.shared_context "when is a gift sender purchase" do
  let(:gift) { create(:gift, link: product, gift_note: "Hope you like it!", giftee_email: "giftee@example.com") }

  before do
    purchase.update!(is_gift_sender_purchase: true, gift_given: gift)
  end
end

RSpec.shared_context "when the purchase has a license" do
  let!(:license) { create(:license, purchase:, link: purchase.link) }

  before do
    purchase.link.update!(is_licensed: true)
  end
end

RSpec.shared_context "when the purchase is for a physical product" do
  let(:product) { create(:product, :is_physical) }
  let(:purchase) { create(:physical_purchase, link: product) }
end

RSpec.shared_context "when the purchase is recurring subscription" do
  let(:shipping_attributes) { {} }
  let(:purchase_attributes) { {}.merge(shipping_attributes) }

  let(:purchase) { create(:recurring_membership_purchase, link: product, **purchase_attributes) }
  let(:sizes_category) { create(:variant_category, title: "sizes", link: product) }
  let(:small_variant) { create(:variant, name: "small", price_difference_cents: 300, variant_category: sizes_category) }
  let(:colors_category) { create(:variant_category, title: "colors", link: product) }
  let(:red_variant) { create(:variant, name: "red", price_difference_cents: 300, variant_category: colors_category) }

  before do
    purchase.subscription.price.update!(recurrence: BasePrice::Recurrence::MONTHLY)
    purchase.variant_attributes << small_variant
    purchase.variant_attributes << red_variant
  end
end
