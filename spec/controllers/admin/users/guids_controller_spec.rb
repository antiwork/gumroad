# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Users::GuidsController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:user1) { create(:user) }
  let(:user2) { create(:user) }
  let(:user3) { create(:user) }
  let(:browser_guid1) { SecureRandom.uuid }
  let(:browser_guid2) { SecureRandom.uuid }
  let(:browser_guid3) { SecureRandom.uuid }
  let(:admin_user) { create(:admin_user) }

  before do
    create(:event, user_id: user1.id, browser_guid: browser_guid1)

    create(:event, user_id: user1.id, browser_guid: browser_guid2)
    create(:event, user_id: user2.id, browser_guid: browser_guid2)

    create(:event, user_id: user1.id, browser_guid: browser_guid3)
    create(:event, user_id: user2.id, browser_guid: browser_guid3)
    create(:event, user_id: user3.id, browser_guid: browser_guid3)

    sign_in admin_user
  end

  describe "GET index" do
    it "returns unique browser GUIDs with unique user IDs for the supplied user ID" do
      get :index, params: { user_external_id: user1.external_id }

      expect(response).to be_successful

      expected_value = [
        { "guid" => browser_guid1, "user_external_ids" => [user1.external_id] },
        { "guid" => browser_guid2, "user_external_ids" => [user1.external_id, user2.external_id] },
        { "guid" => browser_guid3, "user_external_ids" => [user1.external_id, user2.external_id, user3.external_id] }
      ]

      expect(response.parsed_body).to match_array(expected_value)
    end

    it "returns an empty array when no GUIDs are found for the user" do
      user_without_events = create(:user)

      get :index, params: { user_external_id: user_without_events.external_id }

      expect(response).to be_successful
      expect(response.parsed_body).to be_empty
    end

    it "returns only GUIDs associated with the specified user" do
      other_user = create(:user)
      other_guid = SecureRandom.uuid
      create(:event, user_id: other_user.id, browser_guid: other_guid)

      get :index, params: { user_external_id: user2.external_id }

      expect(response).to be_successful

      returned_guids = response.parsed_body.map { |item| item["guid"] }
      expect(returned_guids).to match_array([browser_guid2, browser_guid3])
      expect(returned_guids).not_to include(browser_guid1)
      expect(returned_guids).not_to include(other_guid)
    end
  end
end
