# frozen_string_literal: true

describe InvoicePresenter::OrderInfo do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) do
    create(
      :purchase,
      email: "customer@example.com",
      link: product,
      seller:,
      price_cents: 14_99,
      created_at: DateTime.parse("January 1, 2023")
    )
  end
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
  let(:additional_notes) { "Here is the note!\nIt has multiple lines." }
  let(:business_vat_id) { "VAT12345" }
  let!(:purchase_sales_tax_info) do
    purchase.create_purchase_sales_tax_info!(
      country_code: Compliance::Countries::USA.alpha2
    )
  end
  let(:presenter) { described_class.new(chargeable, address_fields:, additional_notes:, business_vat_id:) }

  RSpec.shared_examples "chargeable" do
    describe "#heading" do
      context "when is not direct to australian customer" do
        it "returns Invoice" do
          expect(presenter.heading).to eq("Invoice")
        end
      end

      context "when is direct to australian customer" do
        it "returns Receipt" do
          allow(chargeable).to receive(:is_direct_to_australian_customer?).and_return(true)
          expect(presenter.heading).to eq("Receipt")
        end
      end
    end

    describe "#pdf_attributes" do
      before do
        purchase.update!(was_purchase_taxable: true, tax_cents: 100)
      end

      it "returns an Array of attributes" do
        expect(presenter.pdf_attributes).to eq(
          [
            {
              label: "Date",
              value: "Jan 1, 2023",
            },
            {
              label: "Order number",
              value: purchase.external_id_numeric.to_s,
            },
            {
              label: "To",
              value: "Customer Name<br>1234 Main St<br>City, State, 12345<br>United States"
            },
            {
              label: "Additional notes",
              value: "<p>Here is the note!\n<br />It has multiple lines.</p>",
            },
            {
              label: "VAT ID",
              value: "VAT12345",
            },
            {
              label: nil,
              value: "Reverse Charge - You are required to account for the VAT",
            },
            {
              label: "Email",
              value: "customer@example.com",
            },
            {
              label: "Item purchased",
              value: nil,
            },
            {
              label: "The Works of Edgar Gumstein",
              value: "$14.99",
            },
            {
              label: "Sales tax (included)",
              value: "$1",
            },
            {
              label: "Payment Total",
              value: "$14.99",
            },
            {
              label: "Payment method",
              value: "VISA *4062",
            }
          ]
        )
      end

      context "when country is Australia" do
        before do
          purchase.update!(gumroad_tax_cents: 100, was_purchase_taxable: true)
          purchase_sales_tax_info.update!(country_code: Compliance::Countries::AUS.alpha2)
        end

        it "returns correct business VAT ID label" do
          expect(presenter.pdf_attributes).to include(
            {
              label: "ABN ID",
              value: "VAT12345",
            }
          )
        end
      end

      context "when country is Singapore" do
        before do
          purchase.update!(gumroad_tax_cents: 100, was_purchase_taxable: true)
          purchase_sales_tax_info.update!(country_code: Compliance::Countries::SGP.alpha2)
        end

        it "returns correct business VAT ID label" do
          expect(presenter.pdf_attributes).to include(
            {
              label: "GST ID",
              value: "VAT12345",
            }
          )
        end
      end
    end

    describe "#form_attributes" do
      # Keyword arguments are not passed for the form page
      let(:presenter) { described_class.new(chargeable, address_fields: nil, additional_notes: nil, business_vat_id: nil) }

      it "returns an Array of attributes" do
        expect(presenter.form_attributes).to eq(
          [
            {
              label: "Email",
              value: "customer@example.com",
            },
            {
              label: "Item purchased",
              value: nil,
            },
            {
              label: "The Works of Edgar Gumstein",
              value: "$14.99",
            },
            {
              label: "Payment Total",
              value: "$14.99",
            },
            {
              label: "Payment method",
              value: "VISA *4062",
            }
          ]
        )
      end

      context "with business_vat_id already provided" do
        before do
          purchase.update!(gumroad_tax_cents: 100, was_purchase_taxable: true)
          purchase_sales_tax_info.update!(business_vat_id:)
        end

        it "includes VAT ID attributes" do
          expect(presenter.form_attributes).to include(
            {
              label: "VAT ID",
              value: business_vat_id
            }
          )
          expect(presenter.form_attributes).to include(
            {
              label: nil,
              value: "Reverse Charge - You are required to account for the VAT"
            }
          )
        end
      end
    end
  end

  describe "for Purchase" do
    let(:chargeable) { purchase }

    it_behaves_like "chargeable"
  end

  describe "for Charge" do
    let(:charge) { create(:charge, purchases: [purchase]) }
    let!(:order) { charge.order }
    let(:chargeable) { charge }

    before do
      order.purchases << purchase
      order.update!(created_at: DateTime.parse("January 1, 2023"))
    end

    it_behaves_like "chargeable"

    context "when the charge has a second purchase" do
      let(:second_purchase) do
        create(
          :purchase,
          email: "customer@example.com",
          link: create(:product, name: "Second Product", user: seller),
          seller:,
          displayed_price_cents: 9_99,
          was_purchase_taxable: true,
          tax_cents: 60,
          created_at: DateTime.parse("January 1, 2023")
        )
      end
      before do
        purchase.update!(was_purchase_taxable: true, tax_cents: 100)
        charge.purchases << second_purchase
        order.purchases << second_purchase
      end

      it "sums the tax" do
        expect(presenter.pdf_attributes).to include(
          {
            label: "Sales tax (included)",
            value: "$1.60",
          }
        )
      end

      it "includes second purchase product" do
        expect(presenter.pdf_attributes).to include(
          {
            label: "Second Product",
            value: "$9.99",
          }
        )
      end

      context "with Gumroad tax", :vcr do
        let(:zip_tax_rate) { create(:zip_tax_rate, combined_rate: 0.20, is_seller_responsible: false) }
        let(:valid_bussiness_vat_id) { "51824753556" }
        let(:purchase) { create(:purchase_in_progress, zip_tax_rate:, chargeable: create(:chargeable)) }
        let(:second_purchase) { create(:purchase_in_progress, zip_tax_rate:, chargeable: create(:chargeable)) }
        let(:purchase_sales_tax_info) { PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::AUS.alpha2) }
        let(:presenter) { described_class.new(chargeable, address_fields:, additional_notes:, business_vat_id: valid_bussiness_vat_id) }

        before do
          purchase.process!
          purchase.mark_successful!
          purchase.update!(
            gumroad_tax_cents: 50,
            purchase_sales_tax_info:
          )

          second_purchase.process!
          second_purchase.mark_successful!
          second_purchase.update!(
            gumroad_tax_cents: 100,
            purchase_sales_tax_info:
          )
        end

        context "when the tax was not refunded" do
          it "includes the tax" do
            expect(presenter.pdf_attributes).to include(
              {
                label: "Sales tax (included)",
                value: "$1.50",
              }
            )
          end
        end

        context "when the tax was refunded" do
          before do
            purchase.refund_gumroad_taxes!(refunding_user_id: 1, business_vat_id: valid_bussiness_vat_id)
            second_purchase.refund_gumroad_taxes!(refunding_user_id: 1, business_vat_id: valid_bussiness_vat_id)
          end

          it "subtracts the refunded amounts" do
            expect(presenter.pdf_attributes).not_to include(label: "Sales tax (included)")
          end
        end
      end
    end
  end
end
