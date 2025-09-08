# frozen_string_literal: true

require "spec_helper"

describe "RenderingExtension" do
  describe "#custom_context" do
    let(:pundit_user) { SellerContext.new(user:, seller:) }
    let(:stubbed_view_context) { StubbedViewContext.new(pundit_user) }
    let(:custom_context) { RenderingExtension.custom_context(stubbed_view_context) }

    context "when user is not logged in" do
      let(:user) { nil }
      let(:seller) { nil }

      it "generates correct context" do
        expect(custom_context).to eq(
          {
            design_settings: {
              font: {
                name: "ABC Favorit",
                url: stubbed_view_context.font_url("ABCFavorit-Regular.woff2")
              }
            },
            domain_settings: {
              scheme: PROTOCOL,
              app_domain: DOMAIN,
              root_domain: ROOT_DOMAIN,
              short_domain: SHORT_DOMAIN,
              discover_domain: DISCOVER_DOMAIN,
              third_party_analytics_domain: THIRD_PARTY_ANALYTICS_DOMAIN,
              api_domain: API_DOMAIN,
            },
            user_agent_info: { is_mobile: true },
            logged_in_user: nil,
            current_seller: nil,
            csp_nonce: SecureHeaders.content_security_policy_script_nonce(stubbed_view_context.request),
            locale: "en-US",
            feature_flags: {
              require_email_typo_acknowledgment: false
            }
          }
        )
      end
    end

    context "when user is logged in" do
      context "with admin role for seller" do
        let(:seller) { create(:named_seller) }
        let(:admin_for_seller) { create(:user, username: "adminforseller") }
        let(:pundit_user) { SellerContext.new(user: admin_for_seller, seller:) }

        before do
          create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
        end

        it "generates correct context" do
          expect(custom_context).to eq(
            {
              design_settings: {
                font: {
                  name: "ABC Favorit",
                  url: stubbed_view_context.font_url("ABCFavorit-Regular.woff2")
                }
              },
              domain_settings: {
                scheme: PROTOCOL,
                app_domain: DOMAIN,
                root_domain: ROOT_DOMAIN,
                short_domain: SHORT_DOMAIN,
                discover_domain: DISCOVER_DOMAIN,
                third_party_analytics_domain: THIRD_PARTY_ANALYTICS_DOMAIN,
                api_domain: API_DOMAIN,
              },
              user_agent_info: { is_mobile: true },
              logged_in_user: {
                id: admin_for_seller.external_id,
                email: admin_for_seller.email,
                name: admin_for_seller.name,
                avatar_url: admin_for_seller.avatar_url,
                confirmed: true,
                team_memberships: UserMembershipsPresenter.new(pundit_user:).props,
                policies: {
                  affiliate_requests_onboarding_form: {
                    update: true,
                  },
                  direct_affiliate: {
                    create: true,
                    update: true,
                  },
                  collaborator: {
                    create: true,
                    update: true,
                  },
                  product: {
                    create: true,
                  },
                  product_review_response: {
                    update: true,
                  },
                  balance: {
                    index: true,
                    export: true,
                  },
                  checkout_offer_code: {
                    create: true,
                  },
                  checkout_form: {
                    update: true,
                  },
                  upsell: {
                    create: true,
                  },
                  settings_payments_user: {
                    show: true,
                  },
                  settings_profile: {
                    manage_social_connections: false,
                    update: true,
                    update_username: false
                  },
                  settings_third_party_analytics_user: {
                    update: true
                  },
                  installment: {
                    create: true,
                  },
                  workflow: {
                    create: true,
                  },
                  utm_link: {
                    index: false,
                  },
                  community: {
                    index: false,
                  }
                },
                is_gumroad_admin: false,
                is_impersonating: true,
              },
              current_seller: UserPresenter.new(user: seller).as_current_seller,
              csp_nonce: SecureHeaders.content_security_policy_script_nonce(stubbed_view_context.request),
              locale: "en-US",
              feature_flags: {
                require_email_typo_acknowledgment: false
              }
            }
          )
        end
      end
    end
  end

  private
    class StubbedViewContext
      attr_reader :pundit_user, :request

      def initialize(pundit_user)
        @pundit_user = pundit_user
        @request = ActionDispatch::TestRequest.create
      end

      def controller
        OpenStruct.new(is_mobile?: true, impersonating?: true, http_accept_language: HttpAcceptLanguage::Parser.new(""))
      end

      def font_url(font_name)
        ActionController::Base.helpers.font_url(font_name)
      end
    end
end
