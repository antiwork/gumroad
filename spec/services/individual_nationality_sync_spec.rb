# frozen_string_literal: true

require "spec_helper"

describe "Individual nationality synchronization" do
  let(:user) { create(:user, country: "Greece", email: "seller@example.com") }
  let!(:compliance_info) { create(:user_compliance_info, user:, country: "Greece", nationality: "GR") }
  let!(:merchant_account) { create(:merchant_account, user:, charge_processor_merchant_id: "acct_nationality") }
  let(:stripe_account) do
    Stripe::Account.construct_from(
      id: merchant_account.charge_processor_merchant_id,
      type: "custom", country: "GR", business_type: "individual", default_currency: "eur",
      metadata: { user_compliance_info_id: compliance_info.external_id },
      capabilities: { card_payments: "active", transfers: "active" },
      individual: { verification: { status: "unverified" } },
      charges_enabled: true, payouts_enabled: false,
      requirements: { currently_due: ["individual.nationality"], eventually_due: [], past_due: [] },
      future_requirements: {}
    )
  end

  before do
    allow(Stripe::Account).to receive(:retrieve).with(stripe_account.id).and_return(stripe_account)
    allow(Stripe::Account).to receive(:update).and_return(stripe_account)
  end

  def save_details(**params)
    UpdateUserComplianceInfo.new(compliance_params: ActionController::Parameters.new(params), user:).process
  end

  %w[individual.nationality nationality].each do |field|
    context "with an outstanding #{field} request" do
      let!(:request) { create(:user_compliance_info_request, user:, field_needed: field) }

      it "resends an unchanged saved nationality through account payload diffing" do
        StripeMerchantAccountManager.handle_new_user_compliance_info(compliance_info)

        expect(Stripe::Account).to have_received(:update).with(stripe_account.id, hash_including(individual: hash_including(nationality: "GR")))
      end

      it "resends an unchanged form without creating a compliance revision" do
        result = nil
        expect { result = save_details(nationality: "GR") }.not_to change(UserComplianceInfo, :count)

        expect(result[:success]).to be(true)
        expect(Stripe::Account).to have_received(:update).with(stripe_account.id, hash_including(individual: hash_including(nationality: "GR")))
        expect(request.reload.state).to eq("requested")
      end

      it "does not clear a saved nationality when the form submits a blank" do
        expect(save_details(nationality: "")[:success]).to be(true)

        expect(user.reload.alive_user_compliance_info.nationality).to eq("GR")
        expect(Stripe::Account).to have_received(:update).with(stripe_account.id, hash_including(individual: hash_including(nationality: "GR")))
      end

      it "reports Stripe rejection when resending an unchanged form" do
        allow(Stripe::Account).to receive(:update).and_raise(Stripe::InvalidRequestError.new("Nationality was rejected", "individual[nationality]"))

        expect(save_details(nationality: "GR")).to include(success: false, error_message: "Nationality was rejected")
        expect(request.reload.state).to eq("requested")
      end

      it "keeps the requirement open after an unrelated form change" do
        expect(save_details(first_name: "Alex")[:success]).to be(true)

        expect(request.reload.state).to eq("requested")
        expect(Stripe::Account).to have_received(:update).with(stripe_account.id, hash_including(individual: hash_including(nationality: "GR")))
      end

      it "keeps the requirement open when nationality is entered for the first time" do
        compliance_info.nationality = nil
        compliance_info.update_column(:json_data, compliance_info.json_data)

        expect(save_details(nationality: "GR")[:success]).to be(true)

        expect(request.reload.state).to eq("requested")
        expect(Stripe::Account).to have_received(:update).with(stripe_account.id, hash_including(individual: hash_including(nationality: "GR")))
      end
    end
  end

  [nil, "", " "].each do |nationality|
    it "omits blank nationality #{nationality.inspect} from the update payload" do
      compliance_info.nationality = nationality
      compliance_info.update_column(:json_data, compliance_info.json_data)
      create(:user_compliance_info_request, user:, field_needed: "nationality")

      StripeMerchantAccountManager.handle_new_user_compliance_info(compliance_info)

      expect(Stripe::Account).to have_received(:update).with(stripe_account.id, hash_including(individual: hash_excluding(:nationality)))
    end
  end

  it "does not resubmit an unchanged form without an outstanding requirement" do
    expect(save_details(nationality: "GR")[:success]).to be(true)

    expect(Stripe::Account).not_to have_received(:update)
  end

  it "preserves local completion and the unchanged-form shortcut for companies" do
    compliance_info.update_columns(is_business: true, business_country: "Greece")
    requests = %w[nationality individual.nationality].map do |field|
      create(:user_compliance_info_request, user:, field_needed: field)
    end

    expect(save_details(nationality: "GR")[:success]).to be(true)

    expect(requests.map { _1.reload.state }).to eq(%w[provided provided])
    expect(Stripe::Account).not_to have_received(:update)
  end

  [false, true].each do |with_nationality|
    it "retains hosted liveness verification with nationality=#{with_nationality}" do
      create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::STRIPE_ENHANCED_IDENTITY_VERIFICATION)
      create(:user_compliance_info_request, user:, field_needed: "nationality") if with_nationality

      expect(save_details(nationality: "GR")[:success]).to be(true)

      presenter = SettingsPresenter.new(pundit_user: SellerContext.new(user:, seller: user))
      props = presenter.payments_props
      expect(props[:account_status][:compliance_actions]).to include(
        message: "Complete pending verification requirements via Stripe",
        href: Rails.application.routes.url_helpers.remediation_settings_payments_path
      )
      expect(props[:user][:has_outstanding_nationality_requirement]).to eq(with_nationality)
      expect(merchant_account.reload.charge_processor_verified_at).to be_nil
    end
  end

  it "retires the requirement only when Stripe no longer requests nationality" do
    request = create(:user_compliance_info_request, user:, field_needed: "nationality")
    save_details(nationality: "GR")
    expect(request.reload.state).to eq("requested")

    stripe_account.requirements.currently_due = []
    StripeMerchantAccountManager.handle_stripe_info_requirements("evt_nationality_resolved", stripe_account, {})

    expect(request.reload.state).to eq("provided")
    presenter = SettingsPresenter.new(pundit_user: SellerContext.new(user:, seller: user))
    expect(presenter.payments_props[:user][:has_outstanding_nationality_requirement]).to be(false)
  end

  %w[AE SG BD PK].each do |country|
    it "preserves individual nationality sending for #{country}" do
      compliance_info.nationality = country
      compliance_info.update_columns(country: Compliance::Countries.mapping.fetch(country), json_data: compliance_info.json_data)
      stripe_account.metadata.user_compliance_info_id = nil

      StripeMerchantAccountManager.handle_new_user_compliance_info(compliance_info)

      expect(Stripe::Account).to have_received(:update).with(stripe_account.id, hash_including(individual: hash_including(nationality: country)))
    end
  end
end
