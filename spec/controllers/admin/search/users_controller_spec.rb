# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::Search::UsersController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }

  before do
    sign_in admin_user
  end

  describe "GET index" do
    let!(:john) { create(:user, name: "John Doe", email: "johnd@gmail.com") }
    let!(:mary) { create(:user, name: "Mary Doe", email: "maryd@gmail.com", external_id: "12345") }
    let!(:derek) { create(:user, name: "Derek Sivers", email: "derek@sive.rs") }
    let!(:jane) { create(:user, name: "Jane Sivers", email: "jane@sive.rs") }

    it "returns successful response with Inertia page data" do
      get :index, params: { query: "Doe" }

      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/Search/Users/Index")
    end

    it "returns JSON response when requested" do
      get :index, params: { query: "Doe" }, format: :json

      expect(response).to be_successful
      expect(response.content_type).to match(%r{application/json})
      expect(response.parsed_body["users"]).to be_present
      expect(response.parsed_body["users"].map { |user| user["id"] }).to match_array([john.external_id, mary.external_id])
      expect(response.parsed_body["pagination"]).to be_present
    end

    it "searches for users with partial email" do
      get :index, params: { query: "sive.rs", format: :json }
      expect(response).to be_successful
      expect(response.content_type).to match(%r{application/json})
      expect(response.parsed_body["users"]).to be_present
      expect(response.parsed_body["users"].map { |user| user["id"] }).to match_array([derek.external_id, jane.external_id])
      expect(response.parsed_body["pagination"]).to be_present
    end

    it "handles empty query" do
      get :index, params: { query: "" }, format: :json
      expect(response).to be_successful
      expect(response.content_type).to match(%r{application/json})
      expect(response.parsed_body["users"]).to be_present
      expect(response.parsed_body["users"].map { |user| user["id"] }).to match_array([admin_user.external_id, john.external_id, mary.external_id, derek.external_id, jane.external_id])
      expect(response.parsed_body["pagination"]).to be_present
    end

    it "paginates results" do
      get :index, params: { query: "Doe", page: 1 }, format: :json
      expect(response).to be_successful
      expect(response.content_type).to match(%r{application/json})
      expect(response.parsed_body["users"]).to be_present
      expect(response.parsed_body["users"].map { |user| user["id"] }).to match_array([john.external_id, mary.external_id])
      expect(response.parsed_body["pagination"]).to be_present
      expect(response).to be_successful
    end
  end
end
