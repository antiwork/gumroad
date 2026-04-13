# frozen_string_literal: true

require "spec_helper"

describe "Settings::Payments account_status", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:named_seller) }

  before do
    create(:user_compliance_info, country: "United States", user: seller)
    allow_any_instance_of(User).to receive(:external_id).and_return("6")
    host! DOMAIN
    sign_in seller
  end

  def account_status
    get settings_payments_path, headers: { "X-Inertia" => "true" }
    expect(response).to be_successful
    JSON.parse(response.body)["props"]["account_status"]
  end

  it "does not show section for compliant user with no issues" do
    seller.mark_compliant!(author_name: "test")

    status = account_status
    expect(status["show_section"]).to be false
    expect(status["is_suspended"]).to be false
    expect(status["suspension_reason"]).to be_nil
    expect(status).not_to have_key("is_under_review")
  end

  it "shows section for user on probation" do
    seller.put_on_probation!(author_name: "test")

    status = account_status
    expect(status["show_section"]).to be true
    expect(status["is_suspended"]).to be false
    expect(status["suspension_reason"]).to be_nil
    expect(status["gumroad_status"]).to include("under review")
    expect(status).not_to have_key("is_under_review")
  end

  it "redirects to login after TOS suspension invalidates the session" do
    seller.flag_for_tos_violation!(author_name: "test", bulk: true)
    seller.suspend_for_tos_violation!(author_name: "test", bulk: true)

    get settings_payments_path, headers: { "X-Inertia" => "true" }

    expect(response).to redirect_to(login_path)
  end

  it "redirects to login after fraud suspension invalidates the session" do
    seller.flag_for_fraud!(author_name: "test")
    seller.suspend_for_fraud!(author_name: "test")

    get settings_payments_path, headers: { "X-Inertia" => "true" }

    expect(response).to redirect_to(login_path)
  end

  it "shows section when payouts are paused internally" do
    seller.update!(payouts_paused_internally: true, payouts_paused_by: "admin")

    status = account_status
    expect(status["show_section"]).to be true
  end

  it "shows section with compliance actions when there are pending requests" do
    compliance_request = create(:user_compliance_info_request, user: seller, field_needed: UserComplianceInfoFields::Individual::TAX_ID)
    compliance_request.verification_error = { "message" => "Please provide your tax ID" }
    compliance_request.save!

    status = account_status
    expect(status["show_section"]).to be true
    expect(status["compliance_actions"]).to include({ "message" => "Please provide your tax ID.", "href" => nil })
  end

  it "combines country-aware field labels into one sentence for pending requests without a verification error message" do
    create(:user_compliance_info_request, user: seller, field_needed: UserComplianceInfoFields::Individual::TAX_ID)
    create(:user_compliance_info_request, user: seller, field_needed: UserComplianceInfoFields::Individual::DATE_OF_BIRTH)

    status = account_status
    expect(status["show_section"]).to be true
    expect(status["compliance_actions"]).to include({ "message" => "Please provide: Social Security Number (SSN) and Date of birth.", "href" => nil })
  end
end
