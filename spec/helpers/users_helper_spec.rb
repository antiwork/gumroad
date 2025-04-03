# frozen_string_literal: true

require "spec_helper"

describe UsersHelper do
  describe "#allowed_avatar_extensions" do
    it "returns supported profile picture extensions separated by comma" do
      extensions = User::ALLOWED_AVATAR_EXTENSIONS.map { |extension| ".#{extension}" }.join(",")
      expect(helper.allowed_avatar_extensions).to eq extensions
    end
  end

  describe "#is_third_party_analytics_enabled?" do
    let(:seller) { create(:named_seller) }
    let(:logged_in_seller) { create(:user) }

    context "without seller known" do
      it "returns 'true' by default" do
        expect(
          helper.is_third_party_analytics_enabled?(seller: nil, logged_in_seller: nil)
        ).to eq true
      end
    end

    context "with seller known" do
      context "when environment is production or staging" do
        before do
          allow(Rails.env).to receive(:production?).and_return(true)
        end

        context "with seller param" do
          context "with logged_in_seller param and signed in" do
            before do
              sign_in logged_in_seller
              logged_in_seller.disable_third_party_analytics = true
            end

            it "uses seller's preference" do
              seller.disable_third_party_analytics = false
              expect(
                helper.is_third_party_analytics_enabled?(seller:, logged_in_seller:)
              ).to eq true

              seller.disable_third_party_analytics = true
              expect(
                helper.is_third_party_analytics_enabled?(seller:, logged_in_seller:)
              ).to eq false
            end
          end

          context "without logged_in_seller param" do
            it "uses seller's preference" do
              seller.disable_third_party_analytics = false
              expect(
                helper.is_third_party_analytics_enabled?(seller:, logged_in_seller: nil)
              ).to eq true

              seller.disable_third_party_analytics = true
              expect(
                helper.is_third_party_analytics_enabled?(seller:, logged_in_seller: nil)
              ).to eq false
            end
          end
        end

        context "without seller param" do
          context "with logged_in_seller param" do
            context "with logged_in_seller not signed in" do
              it "ignores logged_in_seller param and returns 'true' by default" do
                logged_in_seller.disable_third_party_analytics = false
                expect(
                  helper.is_third_party_analytics_enabled?(seller: nil, logged_in_seller: nil)
                ).to eq true

                logged_in_seller.disable_third_party_analytics = true
                expect(
                  helper.is_third_party_analytics_enabled?(seller: nil, logged_in_seller: nil)
                ).to eq true
              end
            end

            context "with logged_in_seller signed in" do
              before do
                sign_in logged_in_seller
              end

              it "uses logged_in_seller's preference" do
                logged_in_seller.disable_third_party_analytics = false
                expect(
                  helper.is_third_party_analytics_enabled?(seller: nil, logged_in_seller:)
                ).to eq true

                logged_in_seller.disable_third_party_analytics = true
                expect(
                  helper.is_third_party_analytics_enabled?(seller: nil, logged_in_seller:)
                ).to eq false
              end
            end
          end
        end
      end

      context "when environment is not production or staging" do
        context "with seller param" do
          it "ignores seller param and returns 'false'" do
            seller.disable_third_party_analytics = false
            expect(
              helper.is_third_party_analytics_enabled?(seller:, logged_in_seller: nil)
            ).to eq false

            seller.disable_third_party_analytics = false
            expect(
              helper.is_third_party_analytics_enabled?(seller:, logged_in_seller: nil)
            ).to eq false
          end
        end
      end
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
