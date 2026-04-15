# frozen_string_literal: true

require "spec_helper"

describe UsersHelper do
  describe "#allowed_avatar_extensions" do
    it "returns supported profile picture extensions separated by comma" do
      extensions = User::ALLOWED_AVATAR_EXTENSIONS.map { |extension| ".#{extension}" }.join(",")
      expect(helper.allowed_avatar_extensions).to eq extensions
    end
  end

  describe "#signed_in_user_home" do
    before do
      @user = create(:user)
    end

    context "when next_url is not present" do
      it "returns dashboard path by default" do
        expect(signed_in_user_home(@user)).to eq Rails.application.routes.url_helpers.dashboard_path
      end

      it "returns library path if not a seller and there are successful purchases" do
        create(:purchase, purchaser_id: @user.id)

        expect(signed_in_user_home(@user)).to eq Rails.application.routes.url_helpers.library_path
      end
    end

    context "when next_url is present" do
      it "returns next_url" do
        expect(signed_in_user_home(@user, next_url: "/sample")).to eq "/sample"
      end
    end

    context "when include_host is present" do
      it "returns library path with host when is_buyer? returns true" do
        allow(@user).to receive(:is_buyer?).and_return(true)

        expect(signed_in_user_home(@user, include_host: true)).to eq Rails.application.routes.url_helpers.library_url(host: UrlService.domain_with_protocol)
      end

      it "returns dashboard path with host by default" do
        expect(signed_in_user_home(@user, include_host: true)).to eq Rails.application.routes.url_helpers.dashboard_url(host: UrlService.domain_with_protocol)
      end
    end
  end
end
