# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe TaxCenterController, type: :controller, inertia: true do
  let(:seller) { create(:user, created_at: 2.years.ago) }

  before do
    Feature.activate_user(:tax_center, seller)
  end

  describe "GET index" do
    include_context "with user signed in as admin for seller"

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { :balance }
    end

    it "renders successfully" do
      travel_to Time.new(2024, 6, 15) do
        create(:user_tax_form, user: seller, tax_year: 2024, tax_form_type: "us_1099_k")

        get :index

        expect(response).to be_successful
        expect(inertia.component).to eq("TaxCenter/Index")
        expect(inertia.props[:tax_center_presenter]).to match(TaxCenterPresenter.new(seller:, year: 2024).props)
        expect(assigns(:title)).to eq("Payouts")
      end
    end

    it "uses the provided year parameter" do
      create(:user_tax_form, user: seller, tax_year: 2023, tax_form_type: "us_1099_k")

      get :index, params: { year: 2023 }

      expect(response).to be_successful
      expect(inertia.props[:tax_center_presenter]).to match(TaxCenterPresenter.new(seller:, year: 2023).props)
    end

    context "when tax_center feature is disabled" do
      before do
        Feature.deactivate_user(:tax_center, seller)
      end

      it "redirects to dashboard with alert" do
        get :index

        expect(response).to redirect_to(dashboard_path)
        expect(flash[:alert]).to eq("Tax center is not enabled for your account.")
      end
    end
  end

  describe "GET download" do
    include_context "with user signed in as admin for seller"

    let(:year) { 2024 }
    let(:form_type) { "us_1099_k" }
    let(:stripe_account_id) { "acct_1234567890" }

    before do
      create(:user_tax_form, user: seller, tax_year: year, tax_form_type: form_type)
      create(:merchant_account, user: seller, charge_processor_merchant_id: stripe_account_id)
    end

    it_behaves_like "authorize called for action", :get, :download do
      let(:record) { :balance }
      let(:policy_method) { :index? }
      let(:request_params) { { year:, form_type: } }
    end

    it "sends the tax form PDF file" do
      pdf_tempfile = Tempfile.new(["tax_form", ".pdf"])
      pdf_tempfile.write("PDF content")
      pdf_tempfile.rewind

      allow_any_instance_of(StripeTaxFormsApi).to receive(:download_tax_form).and_return(pdf_tempfile)

      get :download, params: { year:, form_type: }

      expect(response).to be_successful
      expect(response.headers["Content-Type"]).to eq("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("attachment")
      expect(response.headers["Content-Disposition"]).to include("1099-K-2024.pdf")

      pdf_tempfile.close
      pdf_tempfile.unlink
    end

    context "when tax form does not exist" do
      it "redirects with error message" do
        get :download, params: { year: 2020, form_type: }

        expect(response).to redirect_to(tax_center_path(year: 2020))
        expect(flash[:alert]).to eq("Tax form not available for download.")
      end
    end

    context "when tax form has stripe_account_id stored" do
      it "uses the stored stripe_account_id if it belongs to the seller" do
        tax_form = UserTaxForm.last
        tax_form.stripe_account_id = stripe_account_id
        tax_form.save!

        pdf_tempfile = Tempfile.new(["tax_form", ".pdf"])
        pdf_tempfile.write("PDF content")
        pdf_tempfile.rewind

        allow_any_instance_of(StripeTaxFormsApi).to receive(:download_tax_form).and_return(pdf_tempfile)

        get :download, params: { year:, form_type: }

        expect(response).to be_successful

        pdf_tempfile.close
        pdf_tempfile.unlink
      end
    end

    context "when tax form was filed with a different Stripe account" do
      let(:old_stripe_account_id) { "acct_old_account" }

      before do
        create(:merchant_account, user: seller, charge_processor_merchant_id: old_stripe_account_id)

        tax_form = UserTaxForm.last
        tax_form.stripe_account_id = old_stripe_account_id
        tax_form.save!
      end

      it "uses the old Stripe account stored in the tax form" do
        pdf_tempfile = Tempfile.new(["tax_form", ".pdf"])
        pdf_tempfile.write("PDF content")
        pdf_tempfile.rewind

        allow_any_instance_of(StripeTaxFormsApi).to receive(:download_tax_form).and_return(pdf_tempfile)

        get :download, params: { year:, form_type: }

        expect(response).to be_successful

        pdf_tempfile.close
        pdf_tempfile.unlink
      end
    end

    context "when stored stripe_account_id does not belong to seller" do
      before do
        tax_form = UserTaxForm.last
        tax_form.stripe_account_id = "acct_someone_else"
        tax_form.save
      end

      it "redirects with error message" do
        get :download, params: { year:, form_type: }

        expect(response).to redirect_to(tax_center_path(year:))
        expect(flash[:alert]).to eq("Tax form not available for download.")
      end
    end

    context "when download fails from Stripe API" do
      before do
        allow_any_instance_of(StripeTaxFormsApi).to receive(:download_tax_form).and_return(nil)
      end

      it "redirects with error message" do
        get :download, params: { year:, form_type: }

        expect(response).to redirect_to(tax_center_path(year:))
        expect(flash[:alert]).to eq("Tax form not available for download.")
      end
    end

    context "when tax_center feature is disabled" do
      before do
        Feature.deactivate_user(:tax_center, seller)
      end

      it "redirects to dashboard with alert" do
        get :download, params: { year:, form_type: }

        expect(response).to redirect_to(dashboard_path)
        expect(flash[:alert]).to eq("Tax center is not enabled for your account.")
      end
    end
  end
end
