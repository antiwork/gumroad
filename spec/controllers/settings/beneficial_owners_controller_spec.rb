# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"

describe Settings::BeneficialOwnersController, type: :controller do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }
  let(:stripe_account_id) { "acct_test_beneficial" }
  let(:representative_id) { "person_rep" }
  let(:person_id) { "person_phil" }

  before do
    create(:user_compliance_info_business, user: seller, business_country: "United Kingdom", country: "United Kingdom")
    create(:merchant_account, user: seller, country: "GB", currency: "gbp", charge_processor_merchant_id: stripe_account_id)
    sign_in seller
  end

  let(:other_owner) do
    Stripe::StripeObject.construct_from(
      id: person_id,
      first_name: "Phil",
      last_name: "Owner",
      relationship: { representative: false, owner: true, director: true, percent_ownership: 33.33, title: "Director" },
      address: { line1: "2 High St", city: "London", country: "GB", postal_code: "EC2" },
      dob: { day: 2, month: 2, year: 1981 },
      id_number_provided: true,
      verification: { status: "verified" },
      requirements: { currently_due: [] }
    )
  end

  let(:representative) do
    Stripe::StripeObject.construct_from(
      id: representative_id,
      first_name: "Justin",
      last_name: "Director",
      relationship: { representative: true, owner: true, director: true, percent_ownership: 33.33, title: "CEO" },
      address: { line1: "1 High St", city: "London", country: "GB", postal_code: "EC1" },
      dob: { day: 1, month: 1, year: 1980 },
      id_number_provided: true,
      verification: { status: "verified" },
      requirements: { currently_due: [] }
    )
  end

  describe "GET #index" do
    it "returns every beneficial owner including the representative" do
      allow(Stripe::Account).to receive(:list_persons)
        .with(stripe_account_id, limit: StripeBeneficialOwnersManager::PERSON_LIST_LIMIT)
        .and_return({ "data" => [representative, other_owner] })

      get :index, format: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      ids = body["beneficial_owners"].map { |o| o["id"] }
      expect(ids).to contain_exactly(representative_id, person_id)
      rep_entry = body["beneficial_owners"].find { |o| o["id"] == representative_id }
      expect(rep_entry["relationship"]["representative"]).to be true
    end

    it "returns 403 when the seller is not on a business account" do
      seller.alive_user_compliance_info.mark_deleted!
      create(:user_compliance_info, user: seller, country: "United Kingdom")

      get :index, format: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST #create" do
    let(:params) do
      {
        beneficial_owner: {
          first_name: "Phil",
          last_name: "Owner",
          email: "phil@example.com",
          phone: "+447700900000",
          id_number: "AB123456C",
          title: "Director",
          owner: "true",
          director: "true",
          executive: "false",
          percent_ownership: "33.33",
          dob: { day: "2", month: "2", year: "1981" },
          address: { line1: "2 High St", city: "London", state: "Greater London", postal_code: "EC2", country: "GB" },
        },
      }
    end

    it "creates the Stripe person and returns 201 with the serialized record" do
      allow(Stripe::Account).to receive(:create_person).with(stripe_account_id, anything).and_return(other_owner)

      post :create, params:, format: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["beneficial_owner"]["id"]).to eq(person_id)
    end

    it "returns 422 with the Stripe message when ownership exceeds 100%" do
      allow(Stripe::Account).to receive(:create_person)
        .and_raise(Stripe::InvalidRequestError.new("The total combined ownership of the company would exceed 100 percent.", "relationship[percent_ownership]"))

      post :create, params:, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/exceed 100/)
    end

    it "returns 422 with a clear message when email or phone is missing" do
      missing_params = params.deep_dup
      missing_params[:beneficial_owner][:email] = ""
      missing_params[:beneficial_owner][:phone] = ""

      post :create, params: missing_params, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/Email and Phone are required/)
    end
  end

  describe "PUT #update" do
    let(:params) do
      {
        id: person_id,
        beneficial_owner: {
          first_name: "Phil", last_name: "Owner",
          email: "phil@example.com", phone: "+447700900000",
          title: "Director", owner: "true", director: "true", percent_ownership: "34",
          dob: { day: "2", month: "2", year: "1981" },
        },
      }
    end

    it "updates the Stripe person and returns 200" do
      allow(Stripe::Account).to receive(:retrieve_person).with(stripe_account_id, person_id).and_return(other_owner)
      allow(Stripe::Account).to receive(:update_person).with(stripe_account_id, person_id, anything).and_return(other_owner)

      put :update, params:, format: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["beneficial_owner"]["id"]).to eq(person_id)
    end

    it "allows editing the representative's ownership and role flags" do
      allow(Stripe::Account).to receive(:retrieve_person).with(stripe_account_id, representative_id).and_return(representative)
      allow(Stripe::Account).to receive(:update_person)
        .with(stripe_account_id, representative_id, hash_including(relationship: hash_including(representative: true, percent_ownership: 50.0)))
        .and_return(representative)

      put :update, params: params.merge(id: representative_id, beneficial_owner: { percent_ownership: "50" }), format: :json

      expect(response).to have_http_status(:ok)
    end
  end

  describe "DELETE #destroy" do
    it "deletes the Stripe person and returns 200" do
      allow(Stripe::Account).to receive(:retrieve_person).with(stripe_account_id, person_id).and_return(other_owner)
      allow(Stripe::Account).to receive(:delete_person).with(stripe_account_id, person_id)

      delete :destroy, params: { id: person_id }, format: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("deleted" => true, "id" => person_id)
    end

    it "returns 403 when attempting to delete the representative" do
      allow(Stripe::Account).to receive(:retrieve_person).with(stripe_account_id, representative_id).and_return(representative)

      delete :destroy, params: { id: representative_id }, format: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end
