# frozen_string_literal: true

require "spec_helper"

describe CircleApi, :vcr do
  let(:communities_list) do [
    {
      "id" => 3512,
      "name" => "Gumroad",
      "slug" => "gumroad",
      "icon_url" => "https://d2y5h3osumboay.cloudfront.net/o4431o822um5prcmyefm7pc9fhht",
      "logo_url" => "https://d2y5h3osumboay.cloudfront.net/jwp8ec5m46vtdw05eki9fd38ga7zJ5Hj6yK1",
      "owner_id" => 200455,
      "is_private" => false,
      "space_ids" => [
        24914,
        24916,
        24918,
        24919,
        25148,
        25159,
        27096,
        32841,
        42109,
        42111,
        42112,
        76381,
        77110,
        97329,
        97374,
        97376,
        97377,
        97378,
        98660,
        98664,
        105741,
        105742,
        116356,
        116357,
        132358,
        132553,
        132554,
        132556,
        132557,
        132559,
        132560,
        132561,
        132562,
        132563,
        132565,
        132566,
        132567,
        132568,
        132569,
        132571,
        132573,
        132574,
        132575,
        134985,
        139900,
        140195,
        142769,
        142937
      ],
      "last_visited_by_current_user" => true,
      "default_existing_member_space_id" => 0,
      "root_url" => "community.gumroad.com",
      "display_on_switcher" => true,
      "prefs" => {
        "has_posts" => true,
        "has_spaces" => true,
        "has_topics" => true,
        "brand_color" => "#00959A",
        "has_seen_widget" => true,
        "has_invited_member" => true,
        "has_completed_onboarding" => true
      }
    }
  ] end
  let(:space_groups_list) do [
    {
      "id" => 8015,
      "name" => "Community",
      "is_hidden_from_non_members" => false,
      "allow_members_to_create_spaces" => false,
      "community_id" => 3512,
      "space_order_array" => [
        "77110",
        "24914",
        "32841",
        "132358",
        "25159",
        "97329",
        "76381",
        76381,
        77110,
        134985,
        32841,
        132358,
        24914,
        97329,
        140195
      ],
      "created_at" => "2020-10-17T00:52:17.905Z",
      "updated_at" => "2021-08-06T00:34:52.373Z",
      "automatically_add_members_to_new_spaces" => false,
      "add_members_to_space_group_on_space_join" => false,
      "slug" => "community",
      "hide_non_member_spaces_from_sidebar" => false
    },
    {
      "id" => 8017,
      "name" => "14 Day Product",
      "is_hidden_from_non_members" => true,
      "allow_members_to_create_spaces" => false,
      "community_id" => 3512,
      "space_order_array" => [
        "25148",
        "27096",
        "24918",
        "25157",
        "24916",
        "24919",
        "27095",
        24918,
        27096,
        25148,
        24916,
        24919
      ],
      "created_at" => "2020-10-17T00:56:17.325Z",
      "updated_at" => "2021-04-27T08:42:23.214Z",
      "automatically_add_members_to_new_spaces" => true,
      "add_members_to_space_group_on_space_join" => true,
      "slug" => "14dayproduct",
      "hide_non_member_spaces_from_sidebar" => true
    },
    {
      "id" => 13237,
      "name" => "Sale Every Day",
      "is_hidden_from_non_members" => true,
      "allow_members_to_create_spaces" => false,
      "community_id" => 3512,
      "space_order_array" => [
        42109,
        42111,
        42112
      ],
      "created_at" => "2020-12-14T22:04:07.505Z",
      "updated_at" => "2021-04-27T08:35:31.274Z",
      "automatically_add_members_to_new_spaces" => true,
      "add_members_to_space_group_on_space_join" => true,
      "slug" => "sale-every-day",
      "hide_non_member_spaces_from_sidebar" => true
    },
    {
      "id" => 30973,
      "name" => "Milestones",
      "is_hidden_from_non_members" => true,
      "allow_members_to_create_spaces" => false,
      "community_id" => 3512,
      "space_order_array" => [
        "97352",
        "97340",
        "97343",
        "97346",
        "97348",
        "97349",
        "97351",
        132571,
        132573,
        132574,
        132575
      ],
      "created_at" => "2021-04-27T08:47:11.647Z",
      "updated_at" => "2021-07-20T12:12:13.635Z",
      "automatically_add_members_to_new_spaces" => false,
      "add_members_to_space_group_on_space_join" => false,
      "slug" => "milestones",
      "hide_non_member_spaces_from_sidebar" => true
    },
    {
      "id" => 30981,
      "name" => "Discover",
      "is_hidden_from_non_members" => true,
      "allow_members_to_create_spaces" => false,
      "community_id" => 3512,
      "space_order_array" => [
        "97378",
        "132568",
        "97374",
        "132569",
        "97377",
        "132553",
        "132554",
        "132556",
        "132557",
        "132559",
        "132560",
        "132561",
        "132562",
        "132563",
        "97376",
        "132565",
        "132566",
        "132567",
        132553,
        97374,
        132557,
        132556
      ],
      "created_at" => "2021-04-27T10:34:48.095Z",
      "updated_at" => "2021-08-03T12:08:58.889Z",
      "automatically_add_members_to_new_spaces" => false,
      "add_members_to_space_group_on_space_join" => false,
      "slug" => "discover",
      "hide_non_member_spaces_from_sidebar" => false
    },
    {
      "id" => 31336,
      "name" => "5 Day Email List Course",
      "is_hidden_from_non_members" => true,
      "allow_members_to_create_spaces" => false,
      "community_id" => 3512,
      "space_order_array" => [
        98660,
        98664
      ],
      "created_at" => "2021-04-29T12:11:01.995Z",
      "updated_at" => "2021-04-29T12:22:48.465Z",
      "automatically_add_members_to_new_spaces" => true,
      "add_members_to_space_group_on_space_join" => true,
      "slug" => "5-day-email-list-course",
      "hide_non_member_spaces_from_sidebar" => false
    },
    {
      "id" => 33545,
      "name" => "Grow Your Audience Challenge",
      "is_hidden_from_non_members" => true,
      "allow_members_to_create_spaces" => false,
      "community_id" => 3512,
      "space_order_array" => [
        105741,
        105742
      ],
      "created_at" => "2021-05-15T13:19:57.081Z",
      "updated_at" => "2021-05-15T13:22:10.587Z",
      "automatically_add_members_to_new_spaces" => true,
      "add_members_to_space_group_on_space_join" => true,
      "slug" => "grow-your-audience-challenge",
      "hide_non_member_spaces_from_sidebar" => false
    },
    {
      "id" => 36700,
      "name" => "Sale Every Day Course",
      "is_hidden_from_non_members" => true,
      "allow_members_to_create_spaces" => false,
      "community_id" => 3512,
      "space_order_array" => [
        116356,
        116357
      ],
      "created_at" => "2021-06-08T17:14:16.451Z",
      "updated_at" => "2021-06-08T17:15:48.861Z",
      "automatically_add_members_to_new_spaces" => true,
      "add_members_to_space_group_on_space_join" => true,
      "slug" => "sale-every-day-course",
      "hide_non_member_spaces_from_sidebar" => false
    },
    {
      "id" => 43576,
      "name" => "Tests",
      "is_hidden_from_non_members" => true,
      "allow_members_to_create_spaces" => false,
      "community_id" => 3512,
      "space_order_array" => [
        139900,
        142937
      ],
      "created_at" => "2021-08-05T13:14:01.390Z",
      "updated_at" => "2021-08-12T20:33:12.085Z",
      "automatically_add_members_to_new_spaces" => false,
      "add_members_to_space_group_on_space_join" => false,
      "slug" => "tests",
      "hide_non_member_spaces_from_sidebar" => false
    },
    {
      "id" => 44429,
      "name" => "Drafts",
      "is_hidden_from_non_members" => true,
      "allow_members_to_create_spaces" => false,
      "community_id" => 3512,
      "space_order_array" => [
        142769
      ],
      "created_at" => "2021-08-12T11:37:10.752Z",
      "updated_at" => "2021-08-12T11:37:37.829Z",
      "automatically_add_members_to_new_spaces" => false,
      "add_members_to_space_group_on_space_join" => false,
      "slug" => "drafts",
      "hide_non_member_spaces_from_sidebar" => false
    }
  ] end
  let(:test_community_id) { 3512 }
  let(:test_space_group_id) { 43576 }
  let(:test_member_email) { "circle_test_email@gumroad.com" }

  before do
    @circle_api_handle = CircleApi.new(GlobalConfig.get("CIRCLE_API_KEY"))
  end

  describe "GET communities" do
    it "returns communities for a valid api_key" do
      response = @circle_api_handle.get_communities
      expect(response.parsed_response).to eq(communities_list)
    end

    it "fails if invalid api_key is passed" do
      circle_api_handle = CircleApi.new("invalid_api_key")
      response = circle_api_handle.get_communities
      expect(response.parsed_response).to eq({ "status" => "unauthorized", "message" => "Your account could not be authenticated." })
    end
  end

  describe "GET space_groups" do
    it "returns space_groups for a valid api_key and community_id" do
      response = @circle_api_handle.get_space_groups(test_community_id)
      expect(response.parsed_response).to eq(space_groups_list)
    end

    it "fails if invalid api_key is passed" do
      circle_api_handle = CircleApi.new("invalid_api_key")
      response = circle_api_handle.get_space_groups(test_community_id)
      expect(response.parsed_response).to eq({ "status" => "unauthorized", "message" => "Your account could not be authenticated." })
    end
  end

  describe "POST community_members" do
    it "adds a new member" do
      response = @circle_api_handle.add_member(test_community_id, test_space_group_id, test_member_email)
      expect(response.parsed_response["success"]).to eq(true)
      expect(response.parsed_response["message"]).to eq("This user has been added to the community and has been added to the spaces / space groups specified.")
      expect(response.parsed_response["user"]["email"]).to eq("circle_test_email@gumroad.com")
    end

    it "is successful if member already exists" do
      @circle_api_handle.add_member(test_community_id, test_space_group_id, test_member_email)
      response = @circle_api_handle.add_member(test_community_id, test_space_group_id, test_member_email)
      expect(response.parsed_response["success"]).to eq(true)
      expect(response.parsed_response["message"]).to eq("This user is already a member of this community and has been added to the spaces / space groups specified.")
      expect(response.parsed_response["user"]["email"]).to eq("circle_test_email@gumroad.com")
    end

    it "fails if invalid api_key is passed" do
      circle_api_handle = CircleApi.new("invalid_api_key")
      response = circle_api_handle.add_member(test_community_id, test_space_group_id, test_member_email)
      expect(response.parsed_response).to eq({ "status" => "unauthorized", "message" => "Your account could not be authenticated." })
    end

    it "fails if invalid member email is passed" do
      response = @circle_api_handle.add_member(test_community_id, test_space_group_id, "invalid_email")
      expect(response.parsed_response["success"]).to eq(false)
      expect(response.parsed_response["errors"]).to eq("Email is invalid")
    end
  end

  describe "DELETE community_members" do
    before do
      @circle_api_handle.add_member(test_community_id, test_space_group_id, test_member_email)
    end

    it "deletes an existing member" do
      response = @circle_api_handle.remove_member(test_community_id, test_member_email)
      expect(response.parsed_response["success"]).to eq(true)
      expect(response.parsed_response["message"]).to eq("This user has been removed from the community.")
    end

    it "fails if invalid api_key is passed" do
      circle_api_handle = CircleApi.new("invalid_api_key")
      response = circle_api_handle.remove_member(test_community_id, test_member_email)
      expect(response.parsed_response).to eq({ "status" => "unauthorized", "message" => "Your account could not be authenticated." })
    end

    it "fails if member does not exist" do
      response = @circle_api_handle.remove_member(test_community_id, "not_circle_member@gmail.com")
      expect(response.parsed_response["success"]).to eq(true)
      expect(response.parsed_response["message"]).to eq("This user could not be removed. Please ensure that the user and community specified exists, and that the user is a member of the community.")
    end

    it "fails if invalid member email is passed" do
      response = @circle_api_handle.remove_member(test_community_id, "invalid_email")
      expect(response.parsed_response["success"]).to eq(true)
      expect(response.parsed_response["message"]).to eq("This user could not be removed. Please ensure that the user and community specified exists, and that the user is a member of the community.")
    end
  end
end
