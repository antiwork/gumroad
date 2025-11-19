# frozen_string_literal: true

describe TaxCenterPresenter do
  let(:seller) { create(:user, created_at: Time.new(2020, 9, 21)) }
  let(:presenter) { described_class.new(seller:, year: 2024) }

  before do
    travel_to Time.new(2024, 06, 15)

    Rails.cache.delete("tax_form_data_us_1099_k_2024_#{seller.id}")
  end

  describe "#props" do
    context "when seller has no tax forms" do
      it "returns empty documents with available years and selected year" do
        result = presenter.props

        expect(result.keys).to eq([:documents, :available_years, :selected_year])
        expect(result[:documents]).to eq([])
        expect(result[:available_years]).to eq([2024, 2023, 2022, 2021, 2020])
        expect(result[:selected_year]).to eq(2024)
      end
    end

    context "when seller has a tax form for the year" do
      let!(:tax_form) { create(:user_tax_form, user: seller, tax_year: 2024, tax_form_type: "us_1099_k") }
      let!(:product) { create(:product, user: seller, price_cents: 1000) }
      let!(:purchase_2023) { create(:purchase, link: product, created_at: Time.new(2023, 12, 31)) }

      let!(:purchase_2024_1) { create(:purchase, :with_custom_fee, link: product, created_at: Time.new(2024, 3, 15), fee_cents: 100, tax_cents: 50, gumroad_tax_cents: 30) }

      let!(:purchase_2024_2) do
        purchase = create(:purchase, :with_custom_fee,
                          link: product,
                          created_at: Time.new(2024, 6, 20),
                          fee_cents: 120,
                          gumroad_tax_cents: 25
        )
        purchase.update!(affiliate_credit_cents: 150)
        purchase
      end

      let!(:purchase_2024_3) { create(:purchase, :with_custom_fee, link: product, created_at: Time.new(2024, 9, 10), fee_cents: 80, tax_cents: 75) }

      let!(:refunded_purchase_2024) do
        purchase = create(:purchase, link: product, created_at: Time.new(2024, 4, 1), price_cents: 5000)
        purchase.update!(stripe_refunded: true)
        create(:refund, purchase:, amount_cents: purchase.price_cents)
        purchase
      end

      let!(:purchase_2025) { create(:purchase, link: product, created_at: Time.new(2025, 1, 1)) }

      it "returns document with necessary data" do
        result = presenter.props

        expect(result[:selected_year]).to eq(2024)

        document = result[:documents].sole
        expect(document[:document]).to eq("1099-K")
        expect(document[:type]).to eq("IRS form")
        expect(document[:year]).to eq(2024)
        expect(document[:form_type]).to eq("us_1099_k")
        expect(document[:gross]).to eq("$30.55")
        expect(document[:fees]).to eq("$3.00")
        expect(document[:taxes]).to eq("$1.80")
        expect(document[:affiliate_credit]).to eq("$1.50")
        expect(document[:net]).to eq("$24.25")
      end

      it "caches the document data" do
        presenter.props

        expect(Rails.cache.exist?("tax_form_data_us_1099_k_2024_#{seller.id}")).to be(true)
      end
    end
  end
end
