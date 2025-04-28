# frozen_string_literal: true

describe InvoicePresenter::SupplierInfo do
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
  let(:presenter) { described_class.new(chargeable) }

  RSpec.shared_examples "chargeable" do
    describe "#heading" do
      it "returns Supplier" do
        expect(presenter.heading).to eq("Supplier")
      end
    end

    describe "#attributes" do
      context "when is not supplied by the seller" do
        it "returns Gumroad attributes including the Gumroad note attribute" do
          expect(presenter.attributes).to eq(
            [
              {
                label: nil,
                value: "Gumroad, Inc.",
              },
              {
                label: "Office address",
                value: "548 Market St\nSan Francisco, CA 94104-5401\nUnited States",
              },
              {
                label: "Email",
                value: ApplicationMailer::NOREPLY_EMAIL,
              },
              {
                label: "Web",
                value: ROOT_DOMAIN,
              },
              {
                label: nil,
                value: "Products supplied by Gumroad.",
              }
            ]
          )
        end

        describe "Gumroad tax information" do
          context "with physical product purchase" do
            let(:product) { create(:physical_product, user: seller) }
            let(:purchase) do
              create(
                :purchase,
                email: "customer@example.com",
                link: product,
                seller:,
                created_at: DateTime.parse("January 1, 2023"),
                was_purchase_taxable: true,
                gumroad_tax_cents: 100,
                **address_fields
              )
            end

            context "when country is outside of EU and Australia" do
              before { purchase.update!(country: "United States") }

              it "returns nil" do
                expect(presenter.send(:gumroad_tax_attributes)).to be_nil
              end
            end

            context "when country is in EU" do
              before { purchase.update!(country: "Italy") }

              it "returns VAT information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "VAT Registration Number",
                                                                          value: GUMROAD_VAT_REGISTRATION_NUMBER
                                                                        }
                                                                      ])
              end
            end

            context "when country is Australia" do
              before { purchase.update!(country: "Australia") }

              it "returns ABN information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "Australian Business Number",
                                                                          value: GUMROAD_AUSTRALIAN_BUSINESS_NUMBER
                                                                        }
                                                                      ])
              end
            end

            context "when country is Canada" do
              before { purchase.update!(country: "Canada") }

              it "returns GST and QST information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "Canada GST Registration Number",
                                                                          value: GUMROAD_CANADA_GST_REGISTRATION_NUMBER
                                                                        },
                                                                        {
                                                                          label: "QST Registration Number",
                                                                          value: GUMROAD_QST_REGISTRATION_NUMBER
                                                                        }
                                                                      ])
              end
            end

            context "when country is Norway" do
              before { purchase.update!(country: "Norway") }

              it "returns MVA information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "Norway VAT Registration",
                                                                          value: GUMROAD_NORWAY_VAT_REGISTRATION
                                                                        }
                                                                      ])
              end
            end
          end

          context "when ip_country is in EU" do
            before { purchase.update!(ip_country: "Italy") }

            it "returns VAT information" do
              expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                      {
                                                                        label: "VAT Registration Number",
                                                                        value: GUMROAD_VAT_REGISTRATION_NUMBER
                                                                      }
                                                                    ])
            end
          end

          context "when ip_country is Australia" do
            before do
              purchase.update!(
                country: nil,
                ip_country: "Australia"
              )
            end

            it "returns ABN information" do
              expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                      {
                                                                        label: "Australian Business Number",
                                                                        value: GUMROAD_AUSTRALIAN_BUSINESS_NUMBER
                                                                      }
                                                                    ])
            end
          end

          context "when ip_country is one of the countries that collect tax on all products" do
            before { purchase.update!(country: nil, ip_country: "Iceland") }

            it "returns VAT Registration Number Information" do
              expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                      {
                                                                        label: "VAT Registration Number",
                                                                        value: GUMROAD_OTHER_TAX_REGISTRATION
                                                                      }
                                                                    ])
            end
          end

          context "when ip_country is one of the countries that collect tax on digital products" do
            before { purchase.update!(country: nil, ip_country: "Chile") }

            it "returns VAT Registration Number Information" do
              expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                      {
                                                                        label: "VAT Registration Number",
                                                                        value: GUMROAD_OTHER_TAX_REGISTRATION
                                                                      }
                                                                    ])
            end
          end
        end
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
