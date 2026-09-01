# frozen_string_literal: true

require "spec_helper"

describe OauthScopeHelper do
  describe "#oauth_scope_description" do
    it "describes every configured OAuth scope" do
      configured_scopes = Doorkeeper.configuration.scopes.map(&:to_s)

      expect(OauthScopeHelper::DESCRIPTIONS.keys).to match_array(configured_scopes)
      configured_scopes.each do |scope|
        expect(helper.oauth_scope_description(scope)).to be_present
      end
    end

    it "describes edit_profile so the authorize list does not render an empty bullet" do
      expect(helper.oauth_scope_description("edit_profile")).to eq("Edit your profile name and bio.")
    end

    it "returns nil for unknown scopes so the authorize list can skip them" do
      expect(helper.oauth_scope_description("not_a_real_scope")).to be_nil
    end
  end
end
