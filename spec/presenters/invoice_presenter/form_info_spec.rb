# frozen_string_literal: true

describe InvoicePresenter::FormInfo do
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
  let!(:purchase_sales_tax_info) do
    purchase.create_purchase_sales_tax_info!(
      country_code: Compliance::Countries::USA.alpha2
    )
  end
  let(:presenter) { described_class.new(chargeable) }

  RSpec.shared_examples "chargeable" do
    describe "#heading" do
      context "when is not direct to australian customer" do
        it "returns Generate invoice" do
          expect(presenter.heading).to eq("Generate invoice")
        end
      end

      context "when is direct to australian customer" do
        it "returns Generate receipt" do
          allow(chargeable).to receive(:is_direct_to_australian_customer?).and_return(true)
          expect(presenter.heading).to eq("Generate receipt")
        end
      end
    end

    describe "#display_vat_id?" do
      context "without gumroad tax" do
        it "returns false" do
          expect(presenter.display_vat_id?).to eq(false)
        end
      end

      context "with gumroad tax" do
        before do
          purchase.update!(gumroad_tax_cents: 100, was_purchase_taxable: true)
        end

        context "when business_vat_id has been previously provided" do
          before do
            purchase.purchase_sales_tax_info.update!(business_vat_id: "123")
          end

          it "returns false" do
            expect(presenter.display_vat_id?).to eq(false)
          end
        end

        context "when business_vat_id is missing" do
          it "returns true" do
            expect(presenter.display_vat_id?).to eq(true)
          end
        end
      end
    end

    describe "#vat_id_label" do
      before do
        purchase.update!(was_purchase_taxable: true, gumroad_tax_cents: 100)
      end

      context "when country is Australia" do
        before do
          purchase_sales_tax_info.update!(country_code: Compliance::Countries::AUS.alpha2)
        end

        it "returns ABN" do
          expect(presenter.vat_id_label).to eq("Business ABN ID (Optional)")
        end
      end

      context "when country is Singapore" do
        before do
          purchase_sales_tax_info.update!(country_code: Compliance::Countries::SGP.alpha2)
        end

        it "returns GST" do
          expect(presenter.vat_id_label).to eq("Business GST ID (Optional)")
        end
      end

      context "when country is Norway" do
        before do
          purchase_sales_tax_info.update!(country_code: Compliance::Countries::NOR.alpha2)
        end

        it "returns MVA" do
          expect(presenter.vat_id_label).to eq("Norway MVA ID (Optional)")
        end
      end

      context "when country is something else" do
        it "returns VAT" do
          expect(presenter.vat_id_label).to eq("Business VAT ID (Optional)")
        end
      end
    end

    describe "#data" do
      let(:product) { create(:physical_product, user: seller) }
      let(:address_fields) do
        {
          full_name: "Customer Name",
          street_address: "1234 Main St",
          city: "City",
          state: "State",
          zip_code: "12345",
          country: "United States"
        }
      end
      let(:purchase) do
        create(
          :purchase,
          link: product,
          seller:,
          **address_fields
        )
      end

      it "returns form data" do
        form_data = presenter.data
        address_fields.except(:country).each do |key, value|
          expect(form_data[:address_fields][key]).to eq(value)
        end
        expect(form_data[:address_fields][:country_code]).to eq("US")
        expect(form_data[:email]).to eq(purchase.email)
        expect(form_data[:vat_id]).to eq("")
        expect(form_data[:additional_notes]).to eq("")
      end
    end
  end

  describe "for Purchase" do
    let(:chargeable) { purchase }

    it_behaves_like "chargeable"
  end

  describe "for Charge", :vcr do
    let(:order) { create(:order, purchases: [purchase]) }
    let(:charge) { create(:charge, order:, purchases: [purchase]) }
    let(:chargeable) { charge }

    it_behaves_like "chargeable"
  end
end
