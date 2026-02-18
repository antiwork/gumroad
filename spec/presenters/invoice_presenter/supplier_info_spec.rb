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
      total_transaction_cents: 15_99,
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
                total_transaction_cents: 200,
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

              it "returns GST information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "Canada GST Registration Number",
                                                                          value: GUMROAD_CANADA_GST_REGISTRATION_NUMBER
                                                                        }
                                                                      ])
              end

              context "when province is Quebec" do
                before do
                  purchase.create_purchase_sales_tax_info!(country_code: "CA", state_code: "QC")
                end

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

              context "when province is British Columbia" do
                before do
                  purchase.create_purchase_sales_tax_info!(country_code: "CA", state_code: "BC")
                end

                it "returns GST and BC PST information" do
                  expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                          {
                                                                            label: "Canada GST Registration Number",
                                                                            value: GUMROAD_CANADA_GST_REGISTRATION_NUMBER
                                                                          },
                                                                          {
                                                                            label: "BC PST Registration Number",
                                                                            value: GUMROAD_CANADA_BC_PST
                                                                          }
                                                                        ])
                end
              end

              context "when province is Saskatchewan" do
                before do
                  purchase.create_purchase_sales_tax_info!(country_code: "CA", state_code: "SK")
                end

                it "returns GST and SK PST information" do
                  expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                          {
                                                                            label: "Canada GST Registration Number",
                                                                            value: GUMROAD_CANADA_GST_REGISTRATION_NUMBER
                                                                          },
                                                                          {
                                                                            label: "SK PST Registration Number",
                                                                            value: GUMROAD_CANADA_SK_PST
                                                                          }
                                                                        ])
                end
              end

              context "when province is Manitoba" do
                before do
                  purchase.create_purchase_sales_tax_info!(country_code: "CA", state_code: "MB")
                end

                it "returns GST and MB RST information" do
                  expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                          {
                                                                            label: "Canada GST Registration Number",
                                                                            value: GUMROAD_CANADA_GST_REGISTRATION_NUMBER
                                                                          },
                                                                          {
                                                                            label: "MB RST Registration Number",
                                                                            value: GUMROAD_CANADA_MB_RST
                                                                          }
                                                                        ])
                end
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

          context "when ip_country is one of the countries that collect tax on all products without specific tax ID" do
            before { purchase.update!(country: nil, ip_country: "Iceland") }

            it "returns nil" do
              expect(presenter.send(:gumroad_tax_attributes)).to be_nil
            end
          end

          context "when ip_country is one of the countries that collect tax on digital products without specific tax ID" do
            before { purchase.update!(country: nil, ip_country: "Chile") }

            it "returns nil" do
              expect(presenter.send(:gumroad_tax_attributes)).to be_nil
            end
          end

          context "when country is United Kingdom" do
            before { purchase.update!(country: "United Kingdom") }

            it "returns UK VAT information" do
              expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                      {
                                                                        label: "UK VAT Registration",
                                                                        value: GUMROAD_UK_VAT_REGISTRATION
                                                                      }
                                                                    ])
            end
          end

          context "when country is India" do
            before { purchase.update!(country: nil, ip_country: "India") }

            it "returns GSTIN information" do
              expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                      {
                                                                        label: "GSTIN",
                                                                        value: GUMROAD_INDIA_GSTIN
                                                                      }
                                                                    ])
            end
          end

          context "when country is Japan" do
            before { purchase.update!(country: nil, ip_country: "Japan") }

            it "returns JCT information" do
              expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                      {
                                                                        label: "JCT Registration Number",
                                                                        value: GUMROAD_JAPAN_JCT
                                                                      }
                                                                    ])
            end
          end

          context "when country is New Zealand" do
            before { purchase.update!(country: nil, ip_country: "New Zealand") }

            it "returns New Zealand GST information" do
              expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                      {
                                                                        label: "New Zealand GST",
                                                                        value: GUMROAD_NEW_ZEALAND_GST
                                                                      }
                                                                    ])
            end
          end

          context "when country is Nigeria" do
            before { purchase.update!(country: nil, ip_country: "Nigeria") }

            it "returns FIRS TIN information" do
              expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                      {
                                                                        label: "FIRS TIN",
                                                                        value: GUMROAD_NIGERIA_TIN
                                                                      }
                                                                    ])
            end
          end

          context "when country is Singapore" do
            before { purchase.update!(country: nil, ip_country: "Singapore") }

            it "returns Singapore GST information" do
              expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                      {
                                                                        label: "Singapore GST",
                                                                        value: GUMROAD_SINGAPORE_GST
                                                                      }
                                                                    ])
            end
          end

          context "when country is South Korea" do
            before { purchase.update!(country: nil, ip_country: "South Korea") }

            it "returns South Korea VAT information" do
              expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                      {
                                                                        label: "South Korea VAT",
                                                                        value: GUMROAD_SOUTH_KOREA_VAT
                                                                      }
                                                                    ])
            end
          end

          context "when country is Switzerland" do
            before { purchase.update!(country: nil, ip_country: "Switzerland") }

            it "returns Switzerland VAT information" do
              expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                      {
                                                                        label: "Switzerland VAT",
                                                                        value: GUMROAD_SWITZERLAND_VAT
                                                                      }
                                                                    ])
            end
          end

          context "when country is Thailand" do
            before { purchase.update!(country: nil, ip_country: "Thailand") }

            it "returns Thailand VAT information" do
              expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                      {
                                                                        label: "Thailand VAT",
                                                                        value: GUMROAD_THAILAND_VAT
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
