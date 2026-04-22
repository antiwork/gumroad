# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::TaxFormsController do
  let(:seller) { create(:user, created_at: Time.new(2022, 1, 1)) }
  let(:app) { create(:oauth_application, owner: create(:user)) }
  let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: seller.id, scopes: "view_tax_data") }

  before do
    travel_to Time.new(2026, 4, 15)
    create(:user_compliance_info, user: seller)
    Feature.activate_user(:tax_center, seller)
  end

  describe "GET 'index'" do
    before do
      @action = :index
      @params = {}
    end

    it_behaves_like "authorized oauth v1 api method"

    context "when authenticated with view_tax_data scope" do
      before do
        @params.merge!(format: :json, access_token: token.token)
      end

      it "returns 403 with empty body when token is missing the view_tax_data scope" do
        other_token = create("doorkeeper/access_token", application: app, resource_owner_id: seller.id, scopes: "view_sales")
        get :index, params: @params.merge(access_token: other_token.token)

        expect(response.status).to eq(403)
        expect(response.body.strip).to be_empty
      end

      it "returns 403 when tax_center is not enabled for the seller" do
        Feature.deactivate_user(:tax_center, seller)
        get :index, params: @params

        expect(response.status).to eq(403)
        expect(response.parsed_body).to eq({
          success: false,
          message: "Tax center is not enabled for this account."
        }.as_json)
      end

      it "returns 403 when seller is not US-based" do
        seller.alive_user_compliance_info.mark_deleted!
        create(:user_compliance_info_singapore, user: seller)

        get :index, params: @params

        expect(response.status).to eq(403)
      end

      it "returns an empty list when the seller has no forms" do
        get :index, params: @params

        expect(response).to be_successful
        expect(response.parsed_body).to eq({ success: true, tax_forms: [] }.as_json)
      end

      it "returns all forms across years when year is omitted" do
        create(:user_tax_form, user: seller, tax_year: 2024, tax_form_type: "us_1099_k")
        create(:user_tax_form, user: seller, tax_year: 2025, tax_form_type: "us_1099_k")

        get :index, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["tax_forms"].map { |f| f["tax_year"] }).to contain_exactly(2024, 2025)
      end

      it "filters forms by year" do
        create(:user_tax_form, user: seller, tax_year: 2024, tax_form_type: "us_1099_k")
        form_2025 = create(:user_tax_form, user: seller, tax_year: 2025, tax_form_type: "us_1099_k")

        get :index, params: @params.merge(year: 2025)

        expect(response).to be_successful
        expect(response.parsed_body["tax_forms"]).to eq([
          {
            tax_year: form_2025.tax_year,
            tax_form_type: form_2025.tax_form_type,
            filed_at: nil
          }.as_json
        ])
      end

      it "returns filed_at as ISO-8601 when the form has been filed" do
        filed_at = Time.utc(2026, 1, 31, 12, 0, 0)
        form = create(:user_tax_form, user: seller, tax_year: 2025, tax_form_type: "us_1099_k")
        form.update!(filed_at: filed_at.to_i)

        get :index, params: @params.merge(year: 2025)

        expect(response.parsed_body["tax_forms"].first["filed_at"]).to eq(filed_at.iso8601)
      end

      it "returns 404 when the year is outside the available range" do
        get :index, params: @params.merge(year: 2019)

        expect(response.status).to eq(404)
        expect(response.parsed_body).to eq({
          success: false,
          message: "Tax forms are not available for 2019."
        }.as_json)
      end

      it "returns 404 when year is a non-scalar param" do
        get :index, params: @params.merge(year: ["2025"])

        expect(response.status).to eq(404)
        expect(response.parsed_body).to eq({
          success: false,
          message: "Tax forms are not available for the requested year."
        }.as_json)
      end

      it "returns 404 when the year is the current year" do
        get :index, params: @params.merge(year: 2026)

        expect(response.status).to eq(404)
      end

      it "returns 404 when the year is before the seller account-creation year" do
        get :index, params: @params.merge(year: 2021)

        expect(response.status).to eq(404)
      end

      it "does not return tax forms belonging to other sellers" do
        other_seller = create(:user)
        create(:user_tax_form, user: other_seller, tax_year: 2025, tax_form_type: "us_1099_k")

        get :index, params: @params

        expect(response.parsed_body["tax_forms"]).to be_empty
      end
    end
  end

  describe "GET 'download'" do
    let(:stripe_account_id) { "acct_seller" }
    let!(:merchant_account) { create(:merchant_account, user: seller, charge_processor_merchant_id: stripe_account_id) }
    let!(:tax_form) do
      form = create(:user_tax_form, user: seller, tax_year: 2025, tax_form_type: "us_1099_k")
      form.stripe_account_id = stripe_account_id
      form.save!
      form
    end

    before do
      @action = :download
      @params = { year: 2025, tax_form_type: "us_1099_k" }
    end

    it_behaves_like "authorized oauth v1 api method"

    context "when authenticated with view_tax_data scope" do
      before do
        @params.merge!(format: :json, access_token: token.token)
      end

      it "returns 403 when the token is missing view_tax_data" do
        other_token = create("doorkeeper/access_token", application: app, resource_owner_id: seller.id, scopes: "view_sales")
        get :download, params: @params.merge(access_token: other_token.token)

        expect(response.status).to eq(403)
        expect(response.body.strip).to be_empty
      end

      it "returns 403 when tax_center is not enabled" do
        Feature.deactivate_user(:tax_center, seller)
        get :download, params: @params

        expect(response.status).to eq(403)
      end

      it "streams the Stripe PDF when the Stripe API returns one" do
        pdf_tempfile = Tempfile.new(["tax_form", ".pdf"])
        pdf_tempfile.write("PDF content")
        pdf_tempfile.rewind

        allow_any_instance_of(StripeTaxFormsApi).to receive(:download_tax_form).and_return(pdf_tempfile)

        get :download, params: @params

        expect(response).to be_successful
        expect(response.content_type).to include("application/pdf")
        expect(response.headers["Content-Disposition"]).to include("attachment")
        expect(response.headers["Content-Disposition"]).to include("1099-K-2025.pdf")

        pdf_tempfile.close
        pdf_tempfile.unlink
      end

      it "proxies the S3 fallback bytes when Stripe returns nil for 1099-K" do
        allow_any_instance_of(StripeTaxFormsApi).to receive(:download_tax_form).and_return(nil)
        allow_any_instance_of(User).to receive(:tax_form_1099_s3_bytes).with(year: 2025).and_return("S3 PDF bytes")

        get :download, params: @params

        expect(response).to be_successful
        expect(response.content_type).to include("application/pdf")
        expect(response.body).to eq("S3 PDF bytes")
      end

      it "returns 404 for 1099-MISC when Stripe returns nil (no S3 fallback for MISC)" do
        misc_form = create(:user_tax_form, user: seller, tax_year: 2025, tax_form_type: "us_1099_misc")
        misc_form.stripe_account_id = stripe_account_id
        misc_form.save!

        allow_any_instance_of(StripeTaxFormsApi).to receive(:download_tax_form).and_return(nil)
        expect_any_instance_of(User).not_to receive(:tax_form_1099_s3_bytes)

        get :download, params: @params.merge(tax_form_type: "us_1099_misc")

        expect(response.status).to eq(404)
        expect(response.parsed_body).to eq({ success: false, message: "Tax form not found." }.as_json)
      end

      it "returns 404 when neither Stripe nor S3 has the form" do
        allow_any_instance_of(StripeTaxFormsApi).to receive(:download_tax_form).and_return(nil)
        allow_any_instance_of(User).to receive(:tax_form_1099_s3_bytes).and_return(nil)

        get :download, params: @params

        expect(response.status).to eq(404)
        expect(response.parsed_body).to eq({ success: false, message: "Tax form not found." }.as_json)
      end

      it "returns 404 when the tax form row does not exist for the seller" do
        get :download, params: @params.merge(year: 2024)

        expect(response.status).to eq(404)
      end

      it "returns 404 when the year is outside the available range" do
        get :download, params: @params.merge(year: 2021)

        expect(response.status).to eq(404)
      end

      it "returns 404 when tax_form_type is invalid" do
        get :download, params: @params.merge(tax_form_type: "us_1099_bogus")

        expect(response.status).to eq(404)
      end

      it "returns 404 when the stored stripe_account_id does not belong to the seller" do
        tax_form.stripe_account_id = "acct_someone_else"
        tax_form.save!

        get :download, params: @params

        expect(response.status).to eq(404)
      end
    end
  end
end
