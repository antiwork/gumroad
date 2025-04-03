# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"

describe Integrations::CircleController, :vcr do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:communities_list) do [
    { "id" => 3512, "name" => "Gumroad", }
  ] end
  let(:space_groups_list) do [
    { "id" => 8015, "name" => "Community" },
    { "id" => 8017, "name" => "14 Day Product" },
    { "id" => 13237, "name" => "Sale Every Day" },
    { "id" => 30973, "name" => "Milestones" },
    { "id" => 30981, "name" => "Discover" },
    { "id" => 31336, "name" => "5 Day Email List Course" },
    { "id" => 33545, "name" => "Grow Your Audience Challenge" },
    { "id" => 36700, "name" => "Sale Every Day Course" },
    { "id" => 43576, "name" => "Tests" },
    { "id" => 44429, "name" => "Drafts" }
  ] end
  let(:communities_url) { CircleApi.base_uri + "/communities" }
  let(:space_groups_url) { CircleApi.base_uri + "/space_groups" }
  let(:community_id_param) { { community_id: 3512 } }

  before do
    @user = create(:user)
    sign_in @user
  end

  describe "GET communities" do
    it "returns communities for a valid api_key" do
      get :communities, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => true, "communities" => communities_list })
    end

    it "fails if user is not signed in" do
      sign_out @user

      get :communities, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }

      expect(response.status).to eq(404)
      expect(response.parsed_body).to eq({ "success" => false, "error" => "Not found" })
    end

    it "fails if request to circle API fails" do
      WebMock.stub_request(:get, communities_url).to_return(status: 500)

      get :communities, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if api_key is not passed" do
      get :communities, format: :json
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if invalid response is received from circle API" do
      WebMock.stub_request(:get, communities_url).to_return(status: 200, body: "invalid_error_response")

      get :communities, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if invalid API key is passed" do
      get :communities, format: :json, params: { api_key: "invalid_api_key" }
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end
  end

  describe "GET space_groups" do
    it "returns space_groups for a valid api_key and community_id" do
      get :space_groups, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }.merge(community_id_param)
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => true, "space_groups" => space_groups_list })
    end

    it "fails if user is not signed in" do
      sign_out @user

      get :space_groups, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }.merge(community_id_param)

      expect(response.status).to eq(404)
      expect(response.parsed_body).to eq({ "success" => false, "error" => "Not found" })
    end

    it "fails if request to circle API fails" do
      WebMock.stub_request(:get, space_groups_url).with(query: community_id_param).to_return(status: 500)

      get :space_groups, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }.merge(community_id_param)
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if api_key is not passed" do
      get :space_groups, format: :json, params: community_id_param
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if community_id is not passed" do
      get :space_groups, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if invalid response is received from circle API" do
      WebMock.stub_request(:get, space_groups_url).with(query: community_id_param).to_return(status: 200, body: "invalid_error_response")

      get :space_groups, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }.merge(community_id_param)
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if invalid API key is passed" do
      get :space_groups, format: :json, params: { api_key: "invalid_api_key" }.merge(community_id_param)
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end
  end

  describe "GET communities_and_space_groups" do
    it "returns communities_and_space_groups for a valid api_key and community_id" do
      get :communities_and_space_groups, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }.merge(community_id_param)
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({
                                           "success" => true,
                                           "communities" => communities_list,
                                           "space_groups" => space_groups_list
                                         })
    end

    it "fails if user is not signed in" do
      sign_out @user

      get :communities_and_space_groups, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }.merge(community_id_param)

      expect(response.status).to eq(404)
      expect(response.parsed_body).to eq({ "success" => false, "error" => "Not found" })
    end

    it "fails if request to circle API space_groups fails" do
      WebMock.stub_request(:get, space_groups_url).with(query: community_id_param).to_return(status: 500)

      get :communities_and_space_groups, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }.merge(community_id_param)
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if request to circle API communities fails" do
      WebMock.stub_request(:get, communities_url).to_return(status: 500)

      get :communities_and_space_groups, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }.merge(community_id_param)
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if api_key is not passed" do
      get :communities_and_space_groups, format: :json, params: community_id_param
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if community_id is not passed" do
      get :communities_and_space_groups, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if invalid response is received from circle API communities" do
      WebMock.stub_request(:get, communities_url).to_return(status: 200, body: "invalid_error_response")

      get :communities_and_space_groups, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }.merge(community_id_param)
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if invalid response is received from circle API space_groups" do
      WebMock.stub_request(:get, space_groups_url).with(query: community_id_param).to_return(status: 200, body: "invalid_error_response")

      get :communities_and_space_groups, format: :json, params: { api_key: GlobalConfig.get("CIRCLE_API_KEY") }.merge(community_id_param)
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "fails if invalid API key is passed" do
      get :communities_and_space_groups, format: :json, params: { api_key: "invalid_api_key" }.merge(community_id_param)
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end
  end
end
