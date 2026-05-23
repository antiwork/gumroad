# frozen_string_literal: true

require "test_helper"

class InvoicePresenterSupplierInfoTest < ActiveSupport::TestCase
  self.described_class = InvoicePresenter::SupplierInfo


  context_ InvoicePresenter::SupplierInfo do
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

    shared_examples "chargeable" do
  context_ "#heading" do
  test "returns Supplier" do
          expect(presenter.heading).to eq("Supplier")
        end
      end

  context_ "#attributes" do
  context_ "when is not supplied by the seller" do
  test "returns Gumroad attributes including the Gumroad note attribute" do
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

  context_ "Gumroad tax information" do
  context_ "with physical product purchase" do
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

  context_ "when country is outside of EU and Australia" do
                before { purchase.update!(country: "United States") }

  test "returns nil" do
                  expect(presenter.send(:gumroad_tax_attributes)).to be_nil
                end
              end

  context_ "when country is in EU" do
                before { purchase.update!(country: "Italy") }

  test "returns VAT information" do
                  expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                          {
                                                                            label: "VAT Registration Number",
                                                                            value: GUMROAD_VAT_REGISTRATION_NUMBER
                                                                          }
                                                                        ])
                end
              end

  context_ "when country is Australia" do
                before { purchase.update!(country: "Australia") }

  test "returns ABN information" do
                  expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                          {
                                                                            label: "Australian Business Number",
                                                                            value: GUMROAD_AUSTRALIAN_BUSINESS_NUMBER
                                                                          }
                                                                        ])
                end
              end

  context_ "when country is Canada" do
                before { purchase.update!(country: "Canada") }

  test "returns GST information" do
                  expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                          {
                                                                            label: "Canada GST Registration Number",
                                                                            value: GUMROAD_CANADA_GST_REGISTRATION_NUMBER
                                                                          }
                                                                        ])
                end

  context_ "when province is Quebec" do
                  before do
                    purchase.create_purchase_sales_tax_info!(country_code: "CA", state_code: "QC")
                  end

  test "returns GST and QST information" do
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

  context_ "when province is British Columbia" do
                  before do
                    purchase.create_purchase_sales_tax_info!(country_code: "CA", state_code: "BC")
                  end

  test "returns GST and BC PST information" do
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

  context_ "when province is Saskatchewan" do
                  before do
                    purchase.create_purchase_sales_tax_info!(country_code: "CA", state_code: "SK")
                  end

  test "returns GST and SK PST information" do
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

  context_ "when province is Manitoba" do
                  before do
                    purchase.create_purchase_sales_tax_info!(country_code: "CA", state_code: "MB")
                  end

  test "returns GST and MB RST information" do
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

  context_ "when country is Norway" do
                before { purchase.update!(country: "Norway") }

  test "returns MVA information" do
                  expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                          {
                                                                            label: "Norway VAT Registration",
                                                                            value: GUMROAD_NORWAY_VAT_REGISTRATION
                                                                          }
                                                                        ])
                end
              end
            end

  context_ "when ip_country is in EU" do
              before { purchase.update!(ip_country: "Italy") }

  test "returns VAT information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "VAT Registration Number",
                                                                          value: GUMROAD_VAT_REGISTRATION_NUMBER
                                                                        }
                                                                      ])
              end
            end

  context_ "when ip_country is Australia" do
              before do
                purchase.update!(
                  country: nil,
                  ip_country: "Australia"
                )
              end

  test "returns ABN information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "Australian Business Number",
                                                                          value: GUMROAD_AUSTRALIAN_BUSINESS_NUMBER
                                                                        }
                                                                      ])
              end
            end

  context_ "when ip_country is one of the countries that collect tax on all products without specific tax ID" do
              before { purchase.update!(country: nil, ip_country: "Iceland") }

  test "returns nil" do
                expect(presenter.send(:gumroad_tax_attributes)).to be_nil
              end
            end

  context_ "when ip_country is one of the countries that collect tax on digital products without specific tax ID" do
              before { purchase.update!(country: nil, ip_country: "Chile") }

  test "returns nil" do
                expect(presenter.send(:gumroad_tax_attributes)).to be_nil
              end
            end

  context_ "when country is United Kingdom" do
              before { purchase.update!(country: "United Kingdom") }

  test "returns UK VAT information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "UK VAT Registration",
                                                                          value: GUMROAD_UK_VAT_REGISTRATION
                                                                        }
                                                                      ])
              end
            end

  context_ "when country is India" do
              before { purchase.update!(country: nil, ip_country: "India") }

  test "returns GSTIN information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "GSTIN",
                                                                          value: GUMROAD_INDIA_GSTIN
                                                                        }
                                                                      ])
              end
            end

  context_ "when country is Japan" do
              before { purchase.update!(country: nil, ip_country: "Japan") }

  test "returns JCT information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "JCT Registration Number",
                                                                          value: GUMROAD_JAPAN_JCT
                                                                        }
                                                                      ])
              end
            end

  context_ "when country is New Zealand" do
              before { purchase.update!(country: nil, ip_country: "New Zealand") }

  test "returns New Zealand GST information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "New Zealand GST",
                                                                          value: GUMROAD_NEW_ZEALAND_GST
                                                                        }
                                                                      ])
              end
            end

  context_ "when country is Nigeria" do
              before { purchase.update!(country: nil, ip_country: "Nigeria") }

  test "returns FIRS TIN information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "FIRS TIN",
                                                                          value: GUMROAD_NIGERIA_TIN
                                                                        }
                                                                      ])
              end
            end

  context_ "when country is Singapore" do
              before { purchase.update!(country: nil, ip_country: "Singapore") }

  test "returns Singapore GST information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "Singapore GST",
                                                                          value: GUMROAD_SINGAPORE_GST
                                                                        }
                                                                      ])
              end
            end

  context_ "when country is South Korea" do
              before { purchase.update!(country: nil, ip_country: "South Korea") }

  test "returns South Korea VAT information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "South Korea VAT",
                                                                          value: GUMROAD_SOUTH_KOREA_VAT
                                                                        }
                                                                      ])
              end
            end

  context_ "when country is Switzerland" do
              before { purchase.update!(country: nil, ip_country: "Switzerland") }

  test "returns Switzerland VAT information" do
                expect(presenter.send(:gumroad_tax_attributes)).to eq([
                                                                        {
                                                                          label: "Switzerland VAT",
                                                                          value: GUMROAD_SWITZERLAND_VAT
                                                                        }
                                                                      ])
              end
            end

  context_ "when country is Thailand" do
              before { purchase.update!(country: nil, ip_country: "Thailand") }

  test "returns Thailand VAT information" do
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
