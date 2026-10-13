# frozen_string_literal: true

require "spec_helper"

describe "Dispute evidence link opened while signed in to another account", type: :request do
  include Devise::Test::IntegrationHelpers
  include_context "without the weekend window extension"

  let(:dispute_evidence) { create(:dispute_evidence) }
  let(:purchase) { dispute_evidence.disputable.purchase_for_dispute_evidence }
  let(:evidence_token) do
    purchase.secure_external_id(
      scope: Purchases::DisputeEvidenceController::SECURE_ID_SCOPE,
      expires_at: dispute_evidence.evidence_link_expires_at
    )
  end
  let(:other_account) { create(:user) }
  let(:explanation) { "This page belongs to the seller account that made the sale. Sign in with that account, or reply to the chargeback email with your statement." }

  before do
    host! DOMAIN
    # Devise builds its mappings when routes are drawn; this spec also runs alone in test-confidence.
    Rails.application.reload_routes!
    create(:merchant_account, user: other_account)
    $redis.sadd(RedisKey.user_ids_with_payment_requirements_key, other_account.id)
    sign_in other_account
  end

  after do
    $redis.srem(RedisKey.user_ids_with_payment_requirements_key, other_account.id)
  end

  def follow_redirect_with_inertia
    get URI.parse(response.location).path, headers: { "X-Inertia" => "true" }
  end

  def inertia_flash
    JSON.parse(response.body).dig("props", "flash")
  end

  it "keeps the explanation when the dashboard redirects again to payment settings" do
    create(:user_compliance_info_request, user: other_account)

    get purchase_dispute_evidence_path(evidence_token)
    expect(response).to redirect_to(dashboard_url)

    follow_redirect_with_inertia
    expect(response).to redirect_to(settings_payments_path)

    follow_redirect_with_inertia
    expect(response).to be_successful
    expect(inertia_flash).to eq("message" => explanation, "status" => "danger")
    expect(response.body).not_to include(purchase.seller.email)
  end

  it "shows the explanation once when the dashboard renders" do
    allow(Stripe::Account).to receive(:retrieve).and_return(double(capabilities: { card_payments: "active", transfers: "active" }))

    get purchase_dispute_evidence_path(evidence_token)
    expect(response).to redirect_to(dashboard_url)

    follow_redirect_with_inertia
    expect(response).to be_successful
    expect(inertia_flash).to eq("message" => explanation, "status" => "danger")

    get dashboard_path, headers: { "X-Inertia" => "true" }
    expect(response).to be_successful
    expect(inertia_flash).to be_nil
  end
end
