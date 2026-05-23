# frozen_string_literal: true

require "test_helper"

class UsersHelperTest < ActionView::TestCase
  self.described_class = UsersHelper
  tests UsersHelper



  context_ UsersHelper do
  context_ "#allowed_avatar_extensions" do
  test "returns supported profile picture extensions separated by comma" do
        extensions = User::ALLOWED_AVATAR_EXTENSIONS.map { |extension| ".#{extension}" }.join(",")
        expect(helper.allowed_avatar_extensions).to eq extensions
      end
    end

  context_ "#signed_in_user_home" do
      before do
        @user = create(:user)
      end

  context_ "when next_url is not present" do
  test "returns dashboard path by default" do
          expect(signed_in_user_home(@user)).to eq Rails.application.routes.url_helpers.dashboard_path
        end

  test "returns library path if not a seller and there are successful purchases" do
          create(:purchase, purchaser_id: @user.id)

          expect(signed_in_user_home(@user)).to eq Rails.application.routes.url_helpers.library_path
        end
      end

  context_ "when next_url is present" do
  test "returns next_url" do
          expect(signed_in_user_home(@user, next_url: "/sample")).to eq "/sample"
        end
      end

  context_ "when include_host is present" do
  test "returns library path with host when is_buyer? returns true" do
          allow(@user).to receive(:is_buyer?).and_return(true)

          expect(signed_in_user_home(@user, include_host: true)).to eq Rails.application.routes.url_helpers.library_url(host: UrlService.domain_with_protocol)
        end

  test "returns dashboard path with host by default" do
          expect(signed_in_user_home(@user, include_host: true)).to eq Rails.application.routes.url_helpers.dashboard_url(host: UrlService.domain_with_protocol)
        end
      end
    end
  end
end
