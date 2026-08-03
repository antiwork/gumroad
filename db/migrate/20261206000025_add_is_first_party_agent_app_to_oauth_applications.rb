# frozen_string_literal: true

class AddIsFirstPartyAgentAppToOauthApplications < ActiveRecord::Migration[7.1]
  def change
    change_table :oauth_applications, bulk: true do |t|
      t.boolean :is_first_party_agent_app, default: false, null: false
      t.index [:owner_id, :owner_type, :is_first_party_agent_app],
              name: "index_oauth_applications_on_owner_and_first_party_agent"
    end
  end
end
