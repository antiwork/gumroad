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

    it "names the selected account in place of 'your' so the bullets cannot read as the member's own account" do
      expect(helper.oauth_scope_description("edit_products", account_name: "Outlier Labs"))
        .to eq("Create new products and edit Outlier Labs's existing products.")
      expect(helper.oauth_scope_description("view_profile", account_name: "Outlier Labs"))
        .to eq("See Outlier Labs's profile data.")
    end

    it "inserts the account name literally, even when it looks like a replacement pattern" do
      expect(helper.oauth_scope_description("view_profile", account_name: "A\\&B \\1"))
        .to eq("See A\\&B \\1's profile data.")
    end

    it "keeps 'your' when no account is selected" do
      expect(helper.oauth_scope_description("view_profile", account_name: nil))
        .to eq("See your profile data.")
    end
  end
end
