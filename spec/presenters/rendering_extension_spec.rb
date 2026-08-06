# frozen_string_literal: true

require "spec_helper"

describe "RenderingExtension" do
  describe "#custom_context" do
    let(:pundit_user) { SellerContext.new(user:, seller:) }
    let(:stubbed_view_context) { StubbedViewContext.new(pundit_user) }
    let(:custom_context) { RenderingExtension.custom_context(stubbed_view_context) }

    before do
      allow_any_instance_of(User).to receive(:eligible_for_store_agent?).and_return(true)
    end

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
              disable_stripe_signup: false,
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
                can_create_brand_account: false,
                # The user factory sets a payment address, so this user has a
                # payout setup that could be carried over to a new brand account.
                has_payout_setup_to_port: true,
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
                  settings_main_user: {
                    update_username: false,
                  },
                  settings_profile: {
                    manage_social_connections: false,
                    update: true,
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
                    index: true,
                  },
                  community: {
                    index: false,
                  },
                  churn: {
                    show: true,
                  },
                  page: {
                    index: true,
                    create: true,
                  },
                  user: {
                    view_store_agent: true,
                    use_store_agent: true,
                  }
                },
                is_gumroad_admin: false,
                is_impersonating: true,
                promoted_nav_items: [],
                agent_nav_badge: nil,
                lazy_load_offscreen_discover_images: false,
              },
              current_seller: UserPresenter.new(user: seller).as_current_seller,
              csp_nonce: SecureHeaders.content_security_policy_script_nonce(stubbed_view_context.request),
              locale: "en-US",
              feature_flags: {
                disable_stripe_signup: false,
              }
            }
          )
        end
      end

      describe "has_payout_setup_to_port" do
        let(:seller) { create(:named_seller) }
        let(:user) { seller }
        let(:pundit_user) { SellerContext.new(user:, seller:) }

        before do
          # The user factory sets a payment address; clear it so each example
          # controls exactly which payout pieces exist.
          user.update!(payment_address: "")
        end

        it "is false when the user's only payout method is a debit card", :vcr do
          # The create-brand-account service cannot copy debit-card payout
          # accounts, so the modal should not offer to carry the setup over.
          create(:card_bank_account, user:)

          expect(custom_context[:logged_in_user][:has_payout_setup_to_port]).to eq(false)
        end

        it "is true when the user has a regular bank account" do
          create(:ach_account, user:)

          expect(custom_context[:logged_in_user][:has_payout_setup_to_port]).to eq(true)
        end
      end

      describe "agent_nav_badge" do
        let(:seller) { create(:named_seller) }
        let(:user) { seller }
        let(:pundit_user) { SellerContext.new(user:, seller:) }

        it "states the row is locked for a seller under the earned-access bar (gumroad-private#1773)" do
          allow(seller).to receive(:eligible_for_store_agent?).and_return(false)

          expect(custom_context[:logged_in_user][:agent_nav_badge]).to eq(AgentPresenter::LOCKED_NAV_BADGE)
        end

        it "is nil once the seller is eligible" do
          allow(seller).to receive(:eligible_for_store_agent?).and_return(true)

          expect(custom_context[:logged_in_user][:agent_nav_badge]).to be_nil
        end

        it "is nil for a role that can't see the tab at all, even when under the bar" do
          # Support role: no owner/admin/marketing, so view_store_agent? is false — the badge
          # would otherwise disclose the seller's sub-threshold revenue status to a role that
          # can't even reach the tab.
          support_member = create(:user)
          create(:team_membership, user: support_member, seller:, role: TeamMembership::ROLE_SUPPORT)
          allow(seller).to receive(:eligible_for_store_agent?).and_return(false)

          result = RenderingExtension.custom_context(StubbedViewContext.new(SellerContext.new(user: support_member, seller:)))

          expect(result[:logged_in_user][:agent_nav_badge]).to be_nil
        end

        it "does not call the unmemoized eligibility predicate a second time" do
          # Regression for gumroad-private#1773: policies_props already resolves eligibility via
          # use_store_agent?, and User#eligible_for_store_agent? is deliberately not memoized
          # (it backs two Elasticsearch aggregations), so a second call would double them.
          expect(seller).to receive(:eligible_for_store_agent?).once.and_return(true)

          custom_context
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
