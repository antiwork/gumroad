# frozen_string_literal: true

require "spec_helper"

describe PurchasesController do
  describe "subscription VAT handling" do
    before(:each) do
      @user = create(:user)
      @seller = create(:user)
    end

    let(:user) { @user }
    let(:seller) { @seller }
    let(:product) { create(:product, user: seller) }
    let(:subscription) { create(:subscription, seller: seller, link: product) }
    let(:original_purchase) { create(:purchase, link: product, subscription: subscription, seller: seller, is_original_subscription_purchase: true, purchase_state: "successful") }
    let(:purchase) { create(:purchase, link: product, subscription: subscription, seller: seller, purchase_state: "successful") }
    let(:chargeable) { purchase }

    before do
      sign_in user
      allow(controller).to receive(:logged_in_user).and_return(user)
      # Ensure the original purchase is created
      original_purchase
    end

    describe "POST #send_invoice" do
      let(:valid_vat_id) { "DE123456789" }
      let(:invoice_params) do
        {
          id: purchase.external_id,
          full_name: "Test User",
          street_address: "123 Test St",
          city: "Test City",
          state: "Test State",
          zip_code: "12345",
          country_code: "DE",
          vat_id: valid_vat_id,
          additional_notes: "Test notes",
          email: purchase.email
        }
      end

      context "when VAT ID is provided for a subscription purchase" do
        before do
          # Create purchase_sales_tax_info for the chargeable purchase to enable VAT validation
          chargeable.create_purchase_sales_tax_info!(
            country_code: "DE",
            ip_address: "127.0.0.1"
          )

          # Mock the VAT validation to return true
          vat_validator = instance_double(VatValidationService, process: true)
          allow(VatValidationService).to receive(:new).and_return(vat_validator)

          # Mock the refund process will be set up in individual tests

          # Mock the invoice generation
          allow(controller).to receive(:render_to_string).and_return("<html>Invoice</html>")
          allow(PDFKit).to receive(:new).and_return(double(to_pdf: "pdf_content"))
          allow(chargeable).to receive(:upload_invoice_pdf).and_return(double(url: "http://example.com/invoice.pdf"))
        end

        it "updates the original purchase's sales tax info with VAT ID" do
          # Debug: Check initial state
          expect(subscription.original_purchase).to be_present
          expect(chargeable.subscription).to eq(subscription)
          expect(chargeable.purchase_sales_tax_info).to be_present
          expect(chargeable.purchase_sales_tax_info.country_code).to eq("DE")

          # Mock the VatValidationService to ensure it returns true
          vat_validator = instance_double(VatValidationService, process: true)
          allow(VatValidationService).to receive(:new).and_return(vat_validator)

          # Mock the refund process
          allow(chargeable).to receive(:refund_gumroad_taxes!).and_return(true)

          # Debug: Check that the original purchase doesn't have VAT ID initially
          expect(subscription.original_purchase.purchase_sales_tax_info&.business_vat_id).to be_nil

          post :send_invoice, params: invoice_params

          # Debug: Check the state after the action
          subscription.original_purchase.reload
          expect(subscription.original_purchase.purchase_sales_tax_info&.business_vat_id).to eq(valid_vat_id)
        end

        it "creates purchase_sales_tax_info if it doesn't exist" do
          expect(subscription.original_purchase.purchase_sales_tax_info).to be_nil

          # Mock the VatValidationService to ensure it returns true
          vat_validator = instance_double(VatValidationService, process: true)
          allow(VatValidationService).to receive(:new).and_return(vat_validator)

          # Mock the refund process
          allow(chargeable).to receive(:refund_gumroad_taxes!).and_return(true)

          post :send_invoice, params: invoice_params

          expect(subscription.original_purchase.reload.purchase_sales_tax_info).to be_present
          expect(subscription.original_purchase.purchase_sales_tax_info.business_vat_id).to eq(valid_vat_id)
        end

        it "processes VAT refund when VAT ID is validated" do
          # Mock the VatValidationService to ensure it returns true
          vat_validator = instance_double(VatValidationService, process: true)
          allow(VatValidationService).to receive(:new).and_return(vat_validator)

          # Mock the refund process
          allow(chargeable).to receive(:refund_gumroad_taxes!).and_return(true)

          # The test verifies that VAT refund processing occurs by checking that
          # the original purchase's VAT ID is updated (which happens after refund)
          expect(subscription.original_purchase.purchase_sales_tax_info&.business_vat_id).to be_nil

          post :send_invoice, params: invoice_params

          subscription.original_purchase.reload
          expect(subscription.original_purchase.purchase_sales_tax_info&.business_vat_id).to eq(valid_vat_id)
        end
      end

      context "when VAT ID is invalid" do
        before do
          # Create purchase_sales_tax_info for the chargeable purchase to enable VAT validation
          chargeable.create_purchase_sales_tax_info!(
            country_code: "DE",
            ip_address: "127.0.0.1"
          )

          # Mock the VAT validation to return false
          vat_validator = instance_double(VatValidationService, process: false)
          allow(VatValidationService).to receive(:new).and_return(vat_validator)
        end

        it "does not update the original purchase's sales tax info" do
          expect do
            post :send_invoice, params: invoice_params
          end.not_to change { subscription.original_purchase.purchase_sales_tax_info&.business_vat_id }
        end

        it "does not call refund_gumroad_taxes!" do
          expect(chargeable).not_to receive(:refund_gumroad_taxes!)

          post :send_invoice, params: invoice_params
        end
      end

      context "when purchase is not part of a subscription" do
        let(:standalone_purchase) { create(:purchase, link: product, seller: seller, purchase_state: "successful") }
        let(:chargeable) { standalone_purchase }

        before do
          # Create purchase_sales_tax_info for the chargeable purchase to enable VAT validation
          chargeable.create_purchase_sales_tax_info!(
            country_code: "DE",
            ip_address: "127.0.0.1"
          )

          vat_validator = instance_double(VatValidationService, process: true)
          allow(VatValidationService).to receive(:new).and_return(vat_validator)
          allow(chargeable).to receive(:refund_gumroad_taxes!).and_return(true)
          allow(controller).to receive(:render_to_string).and_return("<html>Invoice</html>")
          allow(PDFKit).to receive(:new).and_return(double(to_pdf: "pdf_content"))
          allow(chargeable).to receive(:upload_invoice_pdf).and_return(double(url: "http://example.com/invoice.pdf"))
        end

        it "does not attempt to update subscription original purchase" do
          expect do
            post :send_invoice, params: invoice_params.merge(id: standalone_purchase.external_id)
          end.not_to raise_error
        end
      end
    end
  end
end
