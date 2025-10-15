# frozen_string_literal: true

require "spec_helper"

describe PurchasesController do
  describe "gift subscription VAT handling" do
    before(:each) do
      @user = create(:user)
      @seller = create(:user)
    end

    let(:user) { @user }
    let(:seller) { @seller }
    let(:product) { create(:product, user: seller) }
    let(:gift_subscription) { create(:subscription, seller: seller, link: product) }
    let(:gift_sender_purchase) { create(:purchase, link: product, subscription: gift_subscription, seller: seller, is_original_subscription_purchase: true, is_gift_sender_purchase: true) }
    let(:gift_receiver_purchase) { create(:purchase, link: product, subscription: gift_subscription, seller: seller, is_original_subscription_purchase: false, is_gift_receiver_purchase: true) }
    let(:chargeable) { gift_receiver_purchase }

    before do
      # Associate purchases with the subscription
      gift_subscription.purchases << gift_sender_purchase
      gift_subscription.purchases << gift_receiver_purchase

      # Ensure the subscription is saved with the associations
      gift_subscription.save!

      sign_in user
      allow(controller).to receive(:logged_in_user).and_return(user)
    end

    describe "POST #send_invoice for gift subscription" do
      let(:valid_vat_id) { "DE123456789" }
      let(:invoice_params) do
        {
          id: gift_receiver_purchase.external_id,
          email: gift_receiver_purchase.email,
          full_name: "Test User",
          street_address: "123 Test St",
          city: "Test City",
          state: "Test State",
          zip_code: "12345",
          country_code: "DEU",
          vat_id: valid_vat_id,
          additional_notes: "Test notes"
        }
      end

      context "when VAT ID is provided for a gift subscription purchase" do
        before do
          # Create purchase_sales_tax_info for the gift_receiver_purchase (chargeable)
          gift_receiver_purchase.create_purchase_sales_tax_info!(
            country_code: "DEU",
            ip_address: "127.0.0.1",
            postal_code: "12345",
            state_code: nil,
            ip_country_code: "DEU"
          )

          # Mock the VAT validation to return true
          allow_any_instance_of(VatValidationService).to receive(:process).and_return(true)

          # Mock the refund process
          allow(chargeable).to receive(:refund_gumroad_taxes!).and_return(true)

          # Mock the invoice generation
          allow(controller).to receive(:render_to_string).and_return("<html>Invoice</html>")
          allow(PDFKit).to receive(:new).and_return(double(to_pdf: "pdf_content"))
          allow(chargeable).to receive(:upload_invoice_pdf).and_return(double(url: "http://example.com/invoice.pdf"))
        end

        it "updates the true_original_purchase's sales tax info with VAT ID for gift subscriptions" do
          expect(gift_subscription.gift?).to be true
          expect(gift_subscription.true_original_purchase).to eq(gift_sender_purchase)
          expect(gift_subscription.original_purchase).to eq(gift_sender_purchase)

          post :send_invoice, params: invoice_params

          expect(gift_subscription.true_original_purchase.reload.purchase_sales_tax_info&.business_vat_id).to eq(valid_vat_id)
        end

        it "does not update the gift_receiver_purchase for gift subscriptions" do
          expect do
            post :send_invoice, params: invoice_params
          end.not_to change { gift_receiver_purchase.purchase_sales_tax_info&.business_vat_id }
        end

        it "creates purchase_sales_tax_info on true_original_purchase if it doesn't exist" do
          expect(gift_subscription.true_original_purchase.purchase_sales_tax_info).to be_nil

          post :send_invoice, params: invoice_params

          expect(gift_subscription.true_original_purchase.reload.purchase_sales_tax_info).to be_present
          expect(gift_subscription.true_original_purchase.purchase_sales_tax_info.business_vat_id).to eq(valid_vat_id)
        end
      end
    end
  end
end
