# frozen_string_literal: true

require "test_helper"

class InvoicePresenterFormInfoTest < ActiveSupport::TestCase
  self.described_class = InvoicePresenter::FormInfo


  context_ InvoicePresenter::FormInfo do
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

    shared_examples "chargeable" do
  context_ "#heading" do
  context_ "when is not direct to australian customer" do
  test "returns Generate invoice" do
            expect(presenter.heading).to eq("Generate invoice")
          end
        end

  context_ "when is direct to australian customer" do
  test "returns Generate receipt" do
            allow(chargeable).to receive(:is_direct_to_australian_customer?).and_return(true)
            expect(presenter.heading).to eq("Generate receipt")
          end
        end
      end

  context_ "#display_vat_id?" do
  context_ "without gumroad tax" do
  test "returns false" do
            expect(presenter.display_vat_id?).to eq(false)
          end
        end

  context_ "with gumroad tax" do
          before do
            purchase.update!(gumroad_tax_cents: 100, was_purchase_taxable: true)
          end

  context_ "when business_vat_id has been previously provided" do
            before do
              purchase.purchase_sales_tax_info.update!(business_vat_id: "123")
            end

  test "returns false" do
              expect(presenter.display_vat_id?).to eq(false)
            end
          end

  context_ "when business_vat_id is missing" do
  test "returns true" do
              expect(presenter.display_vat_id?).to eq(true)
            end
          end
        end
      end

  context_ "#vat_id_label" do
        before do
          purchase.update!(was_purchase_taxable: true, gumroad_tax_cents: 100)
        end

  context_ "when country is Australia" do
          before do
            purchase_sales_tax_info.update!(country_code: Compliance::Countries::AUS.alpha2)
          end

  test "returns ABN" do
            expect(presenter.vat_id_label).to eq("Business ABN ID (Optional)")
          end
        end

  context_ "when country is Singapore" do
          before do
            purchase_sales_tax_info.update!(country_code: Compliance::Countries::SGP.alpha2)
          end

  test "returns GST" do
            expect(presenter.vat_id_label).to eq("Business GST ID (Optional)")
          end
        end

  context_ "when country is Norway" do
          before do
            purchase_sales_tax_info.update!(country_code: Compliance::Countries::NOR.alpha2)
          end

  test "returns MVA" do
            expect(presenter.vat_id_label).to eq("Norway MVA ID (Optional)")
          end
        end

  context_ "when country is something else" do
  test "returns VAT" do
            expect(presenter.vat_id_label).to eq("Business VAT ID (Optional)")
          end
        end
      end

  context_ "#business_id_country_codes" do
  test "includes all 27 EU member states" do
          eu_country_codes = %w[AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE]
          expect(presenter.business_id_country_codes).to include(*eu_country_codes)
        end

  test "includes the United Kingdom" do
          expect(presenter.business_id_country_codes).to include("GB")
        end

  test "does not include the United States" do
          expect(presenter.business_id_country_codes).not_to include("US")
        end
      end

  context_ "#business_id_labels" do
  test "maps EU member states to VAT ID" do
          labels = presenter.business_id_labels
          %w[DE FR IT ES NL BE IE].each do |code|
            expect(labels[code]).to eq("VAT ID")
          end
        end

  test "maps non-EU jurisdictions to their local label" do
          labels = presenter.business_id_labels
          expect(labels["GB"]).to eq("GB VAT")
          expect(labels["AU"]).to eq("ABN")
          expect(labels["BR"]).to eq("CNPJ")
          expect(labels["MX"]).to eq("RFC")
          expect(labels["JP"]).to eq("Consumption tax")
          expect(labels["CA"]).to eq("GST/HST")
        end

  test "does not include countries outside the business-ID scope" do
          expect(presenter.business_id_labels).not_to have_key("US")
        end
      end

  context_ "#data" do
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

  test "returns form data" do
          form_data = presenter.data
          address_fields.except(:country).each do |key, value|
            expect(form_data[:address_fields][key]).to eq(value)
          end
          expect(form_data[:address_fields][:country_code]).to eq("US")
          expect(form_data[:email]).to eq(purchase.email)
          expect(form_data[:business_name]).to eq("")
          expect(form_data[:vat_id]).to eq("")
          expect(form_data[:additional_notes]).to eq("")
        end
      end
    end

  context_ "for Purchase" do
      let(:chargeable) { purchase }

      it_behaves_like "chargeable"
    end

  context_ "for Charge", :vcr do
      let(:order) { create(:order, purchases: [purchase]) }
      let(:charge) { create(:charge, order:, purchases: [purchase]) }
      let(:chargeable) { charge }

      it_behaves_like "chargeable"
    end
  end
end
