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

  # Exactly what the form sends, so an example that removes one field is testing that field. Notably
  # no country: the form has no picker for it and the controller derives it from the seller.
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
        state: "CA",
        zip_code: "94107",
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

      # The form has no country picker, so a guardian whose country is not derived server-side stays
      # incomplete no matter what the seller types and payouts never unblock.
      it "takes the guardian's country from the seller's own account" do
        post :create, params: valid_params, format: :json

        guardian = seller.guardians.alive.sole
        expect(guardian.country).to eq(seller.alive_user_compliance_info.country)
        expect(guardian.country_code).to eq("US")
      end

      # Their country is the account's, not theirs to choose: accepting one would let a guardian be
      # stored in a country our payment partner cannot add a person on this account in.
      it "ignores a country supplied by the client" do
        post :create, params: valid_params.deep_merge(guardian: { country: "Brazil" }), format: :json

        expect(seller.guardians.alive.sole.country).to eq("United States")
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

      # Nothing else sends the guardian to our payment partner. Attaching one mutates the live
      # compliance revision in place, so none of the revision-created paths that sync an account
      # fire — without this enqueue the seller is told they are done and the requirement that
      # stopped their payouts is never satisfied.
      it "sends the completed guardian to our payment partner" do
        expect do
          post :create, params: valid_params, format: :json
        end.to change { SyncGuardianToStripeJob.jobs.size }.by(1)

        expect(SyncGuardianToStripeJob.jobs.last["args"]).to eq([seller.id])
      end

      it "sends nothing while the guardian is still incomplete" do
        expect do
          post :create, params: valid_params.deep_merge(guardian: { accept_terms: "false" }), format: :json
        end.not_to change { SyncGuardianToStripeJob.jobs.size }
      end

      # A double-click, or a stale second tab. The compliance record holds one guardian and refuses
      # to be repointed, so the naive second create 500s and leaves an unattached row holding an
      # adult's name, date of birth, address and tax id that no surface would ever show again.
      it "treats a second create as an edit of the guardian already attached" do
        post :create, params: valid_params, format: :json
        first = seller.guardians.alive.sole

        post :create, params: valid_params.deep_merge(guardian: { city: "Berkeley" }), format: :json

        expect(response).to have_http_status(:ok)
        expect(seller.reload.guardians.alive.sole).to eq(first)
        expect(first.reload.city).to eq("Berkeley")
      end

      # The rollback that keeps a refused attach from stranding the row.
      it "saves no guardian at all when the attach is refused" do
        allow_any_instance_of(UserComplianceInfo)
          .to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(seller.alive_user_compliance_info))

        expect do
          post :create, params: valid_params, format: :json
        end.not_to change { Guardian.count }

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    # Exempt for the same reason the payout gate exempts them: there is no Gumroad-managed account
    # for a guardian to go on, so collecting one would take an adult's identity details for a
    # verification we cannot perform. The page offers them no form either, which is what keeps the
    # blocked set and the asked set identical.
    it "refuses a seller paid through their own connected Stripe account" do
      create(:user_compliance_info, user: seller, birthday: minor_birthday)
      allow_any_instance_of(User).to receive(:has_stripe_account_connected?).and_return(true)

      post :create, params: valid_params, format: :json

      expect(response).to have_http_status(:forbidden)
      expect(seller.guardians).to be_empty
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

    # Guardians saved before the country was derived are stored with it nil, so payouts stay blocked
    # forever unless a later edit heals them.
    it "fills in a missing country on update" do
      guardian.update_column(:country, nil)

      put :update, params: { id: guardian.external_id, guardian: { city: "Berkeley" } }, format: :json

      guardian.reload
      expect(guardian.country).to eq("United States")
      expect(guardian.has_completed_info?).to be(true)
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
