# frozen_string_literal: true

describe RenewFacebookAccessTokensWorker do
  describe "#perform" do
    before do
      @oauth = double "oauth"
      allow(Koala::Facebook::OAuth).to receive(:new).and_return @oauth
    end

    it "renews tokens for accounts with tokens updated < 30 days ago" do
      create(:user, updated_at: Date.today, facebook_access_token: "old token")
      expect(@oauth).to receive(:exchange_access_token).and_return("new access token")

      RenewFacebookAccessTokensWorker.new.perform
    end

    it "doesn't renew tokens for accounts without tokens" do
      create(:user, updated_at: Date.today, facebook_access_token: nil)
      expect(@oauth).to_not receive(:exchange_access_token)

      RenewFacebookAccessTokensWorker.new.perform
    end

    it "doesn't renew tokens for accounts updated > 30 days ago with or without token" do
      create(:user, updated_at: Date.today - 31, facebook_access_token: nil)
      create(:user, updated_at: Date.today - 31, facebook_access_token: "old old old token")
      expect(@oauth).to_not receive(:exchange_access_token)

      RenewFacebookAccessTokensWorker.new.perform
    end
  end
end
