# frozen_string_literal: true

describe InvoicePresenter::SellerInfo do
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

  RSpec.shared_examples "chargeable" do
    describe "#heading" do
      subject(:presenter) { described_class.new(chargeable) }

      it "returns the seller heading" do
        expect(presenter.heading).to eq("Creator")
      end
    end

    describe "#attributes" do
      subject(:presenter) { described_class.new(chargeable) }

      it "returns seller attributes" do
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

  describe "for Purchase" do
    let(:chargeable) { purchase }

    it_behaves_like "chargeable"
  end

  describe "for Charge", :vcr do
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
