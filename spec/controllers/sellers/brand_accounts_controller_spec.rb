# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"

describe Sellers::BrandAccountsController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:user) { create(:user) }

  let(:valid_params) do
    { brand_account: { email: "brand@example.com", username: "mybrand", name: "My Brand" } }
  end

  describe "POST create" do
    before do
      cookies.encrypted[:current_seller_id] = nil
      sign_in user
    end

    context "when the feature flag is off" do
      it "does not create an account" do
        expect do
          post :create, params: valid_params
        end.not_to change(User, :count)

        expect(response.parsed_body["success"]).to eq(false)
      end
    end

    context "when the feature flag is on" do
      before do
        Feature.activate_user(:brand_accounts, user)
      end

      it "creates the brand account, adds the creator as admin, and switches into it" do
        expect do
          post :create, params: valid_params
        end.to change(User, :count).by(1)

        expect(response.parsed_body["success"]).to eq(true)

        brand_user = User.find_by(email: "brand@example.com")
        expect(brand_user.username).to eq("mybrand")
        expect(brand_user.name).to eq("My Brand")

        membership = brand_user.seller_memberships.find_by(user:)
        expect(membership.role).to eq(TeamMembership::ROLE_ADMIN)

        expect(cookies.encrypted[:current_seller_id]).to eq(brand_user.id)
        expect(flash[:notice]).to eq("My Brand is ready — we sent a confirmation link to brand@example.com. Confirm it before publishing.")
      end

      it "returns the validation message when the account can't be created" do
        create(:user, email: "brand@example.com")

        expect do
          post :create, params: valid_params
        end.not_to change(User, :count)

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error_message"]).to be_present
        expect(cookies.encrypted[:current_seller_id]).to eq(nil)
      end

      context "when the creator's email is not confirmed" do
        let(:user) { create(:unconfirmed_user) }

        it "does not create an account" do
          expect do
            post :create, params: valid_params
          end.not_to change(User, :count)

          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["error_message"]).to match(/confirm your email/i)
        end
      end
    end
  end
end
