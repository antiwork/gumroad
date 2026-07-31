# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"

describe Settings::GuardiansController, type: :controller do
  it_behaves_like "inherits from Sellers::BaseController"

  # 15 today, derived from the current date rather than a literal: a fixed birthday ages past 18 and
  # every example here would silently become an adult-seller example asserting nothing.
  let(:minor_birthday) { 15.years.ago.to_date }
  let(:seller) { create(:named_seller) }

  # Enough for a complete guardian, so an example that removes one field is testing that field.
  let(:valid_params) do
    {
      guardian: {
        first_name: "Dana",
        last_name: "Okafor",
        email: "dana@example.com",
        phone: "4155550123",
        date_of_birth: "1984-06-02",
        street_address: "1 Market St",
        city: "San Francisco",
        state: "California",
        zip_code: "94107",
        country: "United States",
        individual_tax_id: "000000000",
        accept_terms: "true",
      },
    }
  end

  include_context "with user signed in as admin for seller"

  describe "POST create" do
    context "when the seller is aged 13-17 in a supported country" do
      before { create(:user_compliance_info, user: seller, birthday: minor_birthday) }

      # Pundit hands the policy only the LAST element of the `[:settings, :payments, seller]` array
      # the controller authorizes with, so the record here is the seller and the policy class has to
      # be named explicitly rather than inferred from it.
      it_behaves_like "authorize called for action", :post, :create do
        let(:record) { seller }
        let(:policy_klass) { Settings::Payments::UserPolicy }
        let(:policy_method) { :update? }
        let(:request_params) { valid_params }
        let(:request_format) { :json }
      end

      it "creates the guardian and attaches it to the live compliance revision" do
        post :create, params: valid_params, format: :json

        expect(response).to have_http_status(:created)
        guardian = seller.guardians.alive.sole
        expect(guardian.full_name).to eq("Dana Okafor")
        expect(guardian.has_completed_info?).to be(true)
        # The attach is the whole point: a saved guardian nothing points at leaves payouts blocked
        # while the form reports success.
        expect(seller.reload.alive_user_compliance_info.guardian).to eq(guardian)
      end

      it "records the acceptance date and IP alongside the flag" do
        post :create, params: valid_params, format: :json

        guardian = seller.guardians.alive.sole
        # All three, because our payment partner takes them together and drops the whole acceptance
        # block if any is missing — an account that reads ready here and stalls there.
        expect(guardian.stripe_tos_accepted).to be(true)
        expect(guardian.stripe_tos_accepted_at).to be_present
        expect(guardian.stripe_tos_ip).to be_present
      end

      it "does not record acceptance the seller did not give" do
        post :create, params: valid_params.deep_merge(guardian: { accept_terms: "false" }), format: :json

        guardian = seller.guardians.alive.sole
        expect(guardian.stripe_tos_accepted).to be(false)
        expect(guardian.stripe_tos_accepted_at).to be_nil
        expect(guardian.stripe_tos_ip).to be_nil
        expect(guardian.has_completed_info?).to be(false)
      end

      it "never returns the stored tax identifier" do
        post :create, params: valid_params, format: :json

        expect(response.body).not_to include("000000000")
        expect(response.parsed_body["guardian"]).not_to have_key("individual_tax_id")
        expect(response.parsed_body["guardian"]["has_individual_tax_id"]).to be(true)
      end

      it "rejects a guardian who is under 18 themselves" do
        post :create, params: valid_params.deep_merge(guardian: { date_of_birth: 16.years.ago.to_date.to_fs(:db) }), format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to include("must be at least 18 years old")
        expect(seller.guardians.alive).to be_empty
      end
    end

    # The gate that keeps an adult's identity details from being collected where they can serve no
    # purpose. Both of these sellers would have no form rendered, so reaching the endpoint at all
    # means something bypassed the page.
    it "refuses an adult seller" do
      create(:user_compliance_info, user: seller, birthday: 30.years.ago.to_date)

      post :create, params: valid_params, format: :json

      expect(response).to have_http_status(:forbidden)
      expect(seller.guardians).to be_empty
    end

    it "refuses a seller aged 13-17 in a country with no guardian path" do
      create(:user_compliance_info, user: seller, birthday: minor_birthday,
                                    country: "Brazil", state: "SP", zip_code: "01000-000")

      post :create, params: valid_params, format: :json

      expect(response).to have_http_status(:forbidden)
      expect(seller.guardians).to be_empty
    end

    it "refuses a seller with no compliance info at all" do
      post :create, params: valid_params, format: :json

      expect(response).to have_http_status(:forbidden)
      expect(seller.guardians).to be_empty
    end

    # The guardian carries an adult third party's identity details, so who may add one is the same
    # question as who may change payout settings — not "anyone on the team".
    context "when the signed-in user is a support team member for the seller" do
      let(:support_member) { create(:user) }

      before do
        create(:user_compliance_info, user: seller, birthday: minor_birthday)
        create(:team_membership, user: support_member, seller:, role: TeamMembership::ROLE_SUPPORT)
        sign_in support_member
        cookies.encrypted[:current_seller_id] = seller.id
      end

      it "refuses to create a guardian" do
        post :create, params: valid_params, format: :json

        expect(response).to have_http_status(:unauthorized).or have_http_status(:forbidden)
        expect(seller.reload.guardians).to be_empty
      end
    end
  end

  describe "PUT update" do
    let!(:guardian) { create(:guardian, user: seller, city: "Oakland") }

    before do
      create(:user_compliance_info, user: seller, birthday: minor_birthday, guardian:)
    end

    it "updates the guardian in place" do
      put :update, params: { id: guardian.external_id, guardian: { city: "Berkeley" } }, format: :json

      expect(response).to have_http_status(:ok)
      expect(guardian.reload.city).to eq("Berkeley")
      # Edited in place rather than replaced, because the row maps onto one person at our payment
      # partner that we update rather than recreate.
      expect(seller.guardians.alive.count).to eq(1)
    end

    it "keeps the tax identifier on file when the request omits it" do
      put :update, params: { id: guardian.external_id, guardian: { city: "Berkeley" } }, format: :json

      expect(guardian.reload.has_individual_tax_id?).to be(true)
      expect(guardian.has_completed_info?).to be(true)
    end

    # Only ever set, never cleared: an unchecked box on a later edit is the form echoing back a value
    # the seller cannot see, not an adult withdrawing their agreement.
    it "does not clear an acceptance already recorded" do
      accepted_at = guardian.stripe_tos_accepted_at

      put :update, params: { id: guardian.external_id, guardian: { city: "Berkeley", accept_terms: "false" } }, format: :json

      guardian.reload
      expect(guardian.stripe_tos_accepted).to be(true)
      expect(guardian.stripe_tos_accepted_at).to be_within(1.second).of(accepted_at)
    end

    it "cannot reach another seller's guardian" do
      other_guardian = create(:guardian, user: create(:user), first_name: "Someone")

      put :update, params: { id: other_guardian.external_id, guardian: { first_name: "Changed" } }, format: :json

      expect(response).to have_http_status(:not_found)
      expect(other_guardian.reload.first_name).to eq("Someone")
    end

    # A payout-settings save replaces the seller's compliance revision, and the new one carries no
    # guardian. Editing the guardian has to re-attach or the seller is silently unpayable again.
    it "re-attaches the guardian when the live compliance revision was replaced" do
      seller.alive_user_compliance_info.dup_and_save! { |new_info| new_info.guardian_id = nil }
      expect(seller.reload.alive_user_compliance_info.guardian).to be_nil

      put :update, params: { id: guardian.external_id, guardian: { city: "Berkeley" } }, format: :json

      expect(response).to have_http_status(:ok)
      expect(seller.reload.alive_user_compliance_info.guardian).to eq(guardian)
    end
  end
end
