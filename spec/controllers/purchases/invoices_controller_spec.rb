# frozen_string_literal: true

require "spec_helper"

describe Purchases::InvoicesController do
  render_views

  let(:purchase) { create(:purchase) }

  describe "GET confirm" do
    it "renders the confirmation page" do
      get :confirm, params: { id: purchase.external_id }

      expect(response).to be_successful
      expect(response).to render_template("inertia")
    end

    it "adds X-Robots-Tag response header to avoid page indexing" do
      get :confirm, params: { id: purchase.external_id }

      expect(response).to be_successful
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
    end

    it "returns 404 for invalid purchase id" do
      expect do
        get :confirm, params: { id: "invalid" }
      end.to raise_error(ActionController::RoutingError)
    end
  end

  describe "GET new" do
    context "without email parameter" do
      it "redirects to confirm page with warning message" do
        get :new, params: { id: purchase.external_id }

        expect(response).to redirect_to(confirm_generate_invoice_path(purchase.external_id))
        expect(flash[:warning]).to eq("Please enter the purchase's email address to generate the invoice.")
      end
    end

    context "with incorrect email" do
      it "redirects to confirm page with alert message" do
        get :new, params: { id: purchase.external_id, email: "wrong@example.com" }

        expect(response).to redirect_to(confirm_generate_invoice_path(purchase.external_id))
        expect(flash[:alert]).to eq("Incorrect email address. Please try again.")
      end
    end

    context "with correct email" do
      it "renders the invoice form" do
        get :new, params: { id: purchase.external_id, email: purchase.email }

        expect(response).to be_successful
        expect(response).to render_template("inertia")
      end

      it "adds X-Robots-Tag response header to avoid page indexing" do
        get :new, params: { id: purchase.external_id, email: purchase.email }

        expect(response).to be_successful
        expect(response.headers["X-Robots-Tag"]).to eq("noindex")
      end
    end
  end

  describe "POST create" do
    let(:invoice_params) do
      {
        id: purchase.external_id,
        email: purchase.email,
        full_name: "John Doe",
        street_address: "123 Main St",
        city: "San Francisco",
        state: "CA",
        zip_code: "94101",
        country_code: "US",
        additional_notes: ""
      }
    end

    context "without email parameter" do
      it "redirects to confirm page" do
        post :create, params: invoice_params.except(:email)

        expect(response).to redirect_to(confirm_generate_invoice_path(purchase.external_id))
      end
    end

    context "with incorrect email" do
      it "redirects to confirm page" do
        post :create, params: invoice_params.merge(email: "wrong@example.com")

        expect(response).to redirect_to(confirm_generate_invoice_path(purchase.external_id))
      end
    end

    context "with correct email" do
      it "generates an invoice PDF and returns success JSON" do
        allow_any_instance_of(PDFKit).to receive(:to_pdf).and_return("")

        invoice_s3_url = "https://s3.example.com/invoice.pdf"
        s3_double = double(presigned_url: invoice_s3_url)
        allow_any_instance_of(Purchase).to receive(:upload_invoice_pdf).and_return(s3_double)
        allow_any_instance_of(Charge).to receive(:upload_invoice_pdf).and_return(s3_double)

        post :create, params: invoice_params

        expect(response).to be_successful
        json_response = response.parsed_body
        expect(json_response["success"]).to be(true)
        expect(json_response["message"]).to eq("The invoice will be downloaded automatically.")
        expect(json_response["file_location"]).to eq(invoice_s3_url)
      end

      context "with VAT ID for unsuccessful purchase" do
        let(:purchase) { create(:purchase, purchase_state: "in_progress") }

        it "returns error JSON" do
          post :create, params: invoice_params.merge(vat_id: "DE123456789")

          expect(response).to be_successful
          json_response = response.parsed_body
          expect(json_response["success"]).to be(false)
          expect(json_response["message"]).to eq("Your purchase has not been completed by PayPal yet. Please try again soon.")
        end
      end

      context "when invoice generation fails" do
        it "returns error JSON" do
          allow_any_instance_of(PDFKit).to receive(:to_pdf).and_raise(StandardError.new("PDF generation failed"))

          post :create, params: invoice_params

          expect(response).to be_successful
          json_response = response.parsed_body
          expect(json_response["success"]).to be(false)
          expect(json_response["message"]).to eq("Sorry, something went wrong.")
        end
      end
    end
  end
end
