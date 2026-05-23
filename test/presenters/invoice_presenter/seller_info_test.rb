# frozen_string_literal: true

require "test_helper"

class InvoicePresenterSellerInfoTest < ActiveSupport::TestCase
  self.described_class = InvoicePresenter::SellerInfo


  context_ InvoicePresenter::SellerInfo do
    let(:seller) { create(:named_seller, support_email: "seller-support@example.com") }
    let(:product) { create(:product, user: seller) }
    let(:purchase) do
      create(
        :purchase,
        email: "customer@example.com",
        link: product,
        seller:,
        price_cents: 14_99,
        created_at: DateTime.parse("January 1, 2023"),
        was_purchase_taxable: true,
        gumroad_tax_cents: 100,
      )
    end

    shared_examples "chargeable" do
  context_ "#heading" do
        subject(:presenter) { described_class.new(chargeable) }

  test "returns the seller heading" do
          expect(presenter.heading).to eq("Creator")
        end
      end

  context_ "#attributes" do
        subject(:presenter) { described_class.new(chargeable) }

  test "returns seller attributes" do
          expect(presenter.attributes).to eq(
            [
              {
                label: nil,
                value: seller.display_name,
                link: seller.subdomain_with_protocol
              },
              {
                label: "Email",
                value: seller.support_or_form_email
              }
            ]
          )
        end
      end
    end

  context_ "for Purchase" do
      let(:chargeable) { purchase }

      it_behaves_like "chargeable"
    end

  context_ "for Charge", :vcr do
      let(:charge) { create(:charge, seller:, purchases: [purchase]) }
      let!(:order) { charge.order }
      let(:chargeable) { charge }

      before do
        order.purchases << purchase
        order.update!(created_at: DateTime.parse("January 1, 2023"))
      end

      it_behaves_like "chargeable"
    end
  end
end
