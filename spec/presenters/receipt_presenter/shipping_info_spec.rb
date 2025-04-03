# frozen_string_literal: true

require "spec_helper"
require "shared_examples/receipt_presenter_concern"

describe ReceiptPresenter::ShippingInfo do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) do
    create(
      :purchase,
      link: product,
      seller:,
      price_cents: 1_499,
      created_at: DateTime.parse("January 1, 2023")
    )
  end
  let(:presenter) { described_class.new(chargeable) }

  RSpec.shared_examples "for a Chargeable" do
    describe ".new" do
      it "assigns instance variable" do
        expect(presenter.send(:chargeable)).to eq(chargeable)
      end
    end

    it "returns correct title" do
      expect(presenter.title).to eq("Shipping info")
    end

    describe "#attributes" do
      let(:attributes) { presenter.attributes }

      context "when the purchase is for a physical product" do
        include_context "when the purchase is for a physical product"

        let(:purchase_shipping_attributes) do
          {
            full_name: "Edgar Gumstein",
            street_address: "123 Gum Road",
            country: "United States",
            state: "CA",
            zip_code: "94107",
            city: "San Francisco",
          }
        end

        before do
          purchase.link.update!(require_shipping: true)
          purchase.update!(**purchase_shipping_attributes)
        end

        it "includes shipping attributes" do
          expect(attributes).to eq(
            [
              { label: "Shipping to", value: "Edgar Gumstein" },
              { label: "Shipping address", value: "123 Gum Road<br>San Francisco, CA 94107<br>United States" }
            ]
          )
        end
      end

      context "when the purchase is not for a physical product" do
        it "it returns empty shipping attributes" do
          expect(attributes).to eq([])
        end
      end
    end
  end

  describe "for a Purchase" do
    let(:chargeable) { purchase }

    include_examples "for a Chargeable"
  end

  describe "for a Charge", :vcr do
    let(:charge) { create(:charge, purchases: [purchase]) }
    let(:chargeable) { charge }

    include_examples "for a Chargeable"
  end
end
