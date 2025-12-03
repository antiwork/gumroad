# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::GuidsController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:user1) { create(:user) }
  let(:user2) { create(:user) }
  let(:user3) { create(:user) }
  let(:browser_guid) { SecureRandom.uuid }
  let(:admin_user) { create(:admin_user) }

  before do
    create(:event, user_id: user1.id, browser_guid: browser_guid)
    create(:event, user_id: user2.id, browser_guid: browser_guid)
    create(:event, user_id: user3.id, browser_guid: browser_guid)

    sign_in admin_user
  end

  describe "GET show" do
    it "returns successful response with Inertia page data" do
      get :show, params: { id: browser_guid }

      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/Compliance/Guids/Show")
    end

    it "returns unique users for the supplied browser GUID" do
      get :show, params: { id: browser_guid }

      expect(response).to be_successful
      expect(assigns(:users).to_a).to match_array [user1, user2, user3]
    end

    it "returns JSON response when requested" do
      get :show, params: { id: browser_guid }, format: :json

      expect(response).to be_successful
      expect(response.content_type).to match(%r{application/json})
      expect(response.parsed_body["users"]).to be_present
      expect(response.parsed_body["users"].map { |user| user["id"] }).to match_array([user1.external_id, user2.external_id, user3.external_id])
      expect(response.parsed_body["pagination"]).to be_present
    end

    it "returns an empty array when no users are found for the GUID" do
      non_existent_guid = SecureRandom.uuid

      get :show, params: { id: non_existent_guid }

      expect(response).to be_successful
      expect(assigns(:users).to_a).to be_empty
    end

    it "returns only users with events for the specific GUID" do
      other_user = create(:user)
      other_guid = SecureRandom.uuid
      create(:event, user_id: other_user.id, browser_guid: other_guid)

      get :show, params: { id: browser_guid }

      expect(response).to be_successful
      expect(assigns(:users).to_a).to match_array [user1, user2, user3]
      expect(assigns(:users).to_a).not_to include(other_user)
    end

    it "paginates results" do
      get :show, params: { id: browser_guid, page: 1 }, format: :json

      expect(response).to be_successful
      expect(response.content_type).to match(%r{application/json})
      expect(response.parsed_body["users"]).to be_present
      expect(response.parsed_body["users"].map { |user| user["id"] }).to match_array([user1.external_id, user2.external_id, user3.external_id])
      expect(response.parsed_body["pagination"]).to be_present
    end
  end
end
