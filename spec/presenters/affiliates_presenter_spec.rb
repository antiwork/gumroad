# frozen_string_literal: true

describe AffiliatesPresenter do
  describe "#index_props" do
    let(:seller) { create(:named_user) }
    let(:admin_for_seller) { create(:user, username: "adminforseller") }
    let(:support_for_seller) { create(:user, username: "supportforseller") }
    let(:pundit_user) { SellerContext.new(user: admin_for_seller, seller:) }

    before do
      create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
      create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
    end

    let(:affiliate_user) { create(:affiliate_user, name: "Affiliated") }
    let(:product) { create(:product, name: "Gumbot bits", unique_permalink: "test", user: seller) }
    let!(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller:, products: [product]) }
    let!(:affiliate_request) { create(:affiliate_request, seller:) }

    it "returns the necessary props to render the affiliates page" do
      props = described_class.new(pundit_user, should_get_affiliate_requests: true).index_props

      expect(JSON.parse(props.to_json).deep_symbolize_keys!).to match(
      {
        affiliate_requests: [affiliate_request.as_json(pundit_user:)],
        affiliates: [
          {
            id: direct_affiliate.external_id,
            affiliate_user_name: "Affiliated",
            destination_url: nil,
            email: affiliate_user.email,
            fee_percent: 3,
            product_referral_url: direct_affiliate.referral_url_for_product(product),
            apply_to_all_products: true,
            products: [
              {
                id: product.external_id_numeric,
                name: "Gumbot bits",
                fee_percent: 3,
                referral_url: "#{direct_affiliate.referral_url}/test",
                destination_url: nil,
              }
            ]
          }
        ],
        pagination: { page: 1, pages: 1 },
        allow_approve_all_requests: false,
        affiliates_disabled_reason: nil,
      })
    end

    context "when search query is present" do
      context "when partially matching an affiliate user" do
        let(:query) { "affil" }

        it "returns the necessary props to render the affiliates page" do
          props = described_class.new(pundit_user, query:).index_props

          expect(JSON.parse(props.to_json).deep_symbolize_keys!).to match(
          {
            affiliate_requests: [],
            affiliates: [direct_affiliate.as_json],
            pagination: { page: 1, pages: 1 },
            allow_approve_all_requests: false,
            affiliates_disabled_reason: nil,
          })
        end
      end

      context "and value does not match any affiliate users" do
        let(:query) { "gumbot" }

        it "returns the necessary props to render the affiliates page" do
          props = described_class.new(pundit_user, query:).index_props

          expect(JSON.parse(props.to_json).deep_symbolize_keys!).to match(
          {
            affiliate_requests: [],
            affiliates: [],
            pagination: { page: 1, pages: 1 },
            allow_approve_all_requests: false,
            affiliates_disabled_reason: nil,
          })
        end
      end

      context "and value is empty" do
        let(:query) { "" }

        it "returns the necessary props to render the affiliates page" do
          props = described_class.new(pundit_user, query:, should_get_affiliate_requests: true).index_props

          expect(JSON.parse(props.to_json).deep_symbolize_keys!).to match(
          {
            affiliate_requests: [affiliate_request.as_json(pundit_user:)],
            affiliates: [direct_affiliate.as_json],
            pagination: { page: 1, pages: 1 },
            allow_approve_all_requests: false,
            affiliates_disabled_reason: nil,
          })
        end
      end
    end
  end

  describe "#onboarding_form_props" do
    let(:seller) { create(:named_user) }
    let(:admin_for_seller) { create(:user, username: "adminforseller") }
    let(:support_for_seller) { create(:user, username: "supportforseller") }
    let(:pundit_user) { SellerContext.new(user: admin_for_seller, seller:) }

    before do
      create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
      create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
    end

    let!(:product_one) { create(:product, name: "First product", user: seller) }
    let!(:product_two) { create(:product, name: "Learn Ruby", user: seller) }
    let!(:product_three) { create(:product, name: "My product", user: seller, purchase_disabled_at: DateTime.current) }
    let!(:product_four) { create(:product, name: "Microeconomics 101", user: seller) }
    let!(:product_five) { create(:product, name: "A product", user: seller) }
    let!(:archived_product_enabled) { create(:product, name: "Archived product enabled", user: seller, archived: true) }
    let!(:archived_product_not_enabled) { create(:product, name: "Archived product not enabled", user: seller, archived: true) }
    let!(:other_archived_product) { create(:product, name: "Other archived product", user: seller, archived: true) }
    let!(:self_service_affiliate_product_two) { create(:self_service_affiliate_product, seller:, product: product_two, enabled: false) }
    let!(:self_service_affiliate_product_four) { create(:self_service_affiliate_product, seller:, product: product_four, enabled: true) }
    let!(:self_service_affiliate_archived_product) { create(:self_service_affiliate_product, seller:, product: archived_product_enabled, enabled: true) }
    let!(:self_service_affiliate_archived_product_not_enabled) { create(:self_service_affiliate_product, seller:, product: archived_product_not_enabled, enabled: false) }

    it "returns the necessary props to render the affiliate onboarding page" do
      props = described_class.new(pundit_user).onboarding_props

      expect(JSON.parse(props.to_json).deep_symbolize_keys!).to match(
      {
        creator_subdomain: seller.subdomain,
        products: [
          { name: "Archived product enabled", enabled: true, id: archived_product_enabled.external_id_numeric, fee_percent: 5, destination_url: nil },
          { name: "Microeconomics 101", enabled: true, id: product_four.external_id_numeric, fee_percent: 5, destination_url: nil },
          { name: "A product", enabled: false, id: product_five.external_id_numeric, fee_percent: nil, destination_url: nil },
          { name: "First product", enabled: false, id: product_one.external_id_numeric, fee_percent: nil, destination_url: nil },
          { name: "Learn Ruby", enabled: false, id: product_two.external_id_numeric, fee_percent: 5, destination_url: nil },
        ],
        disable_global_affiliate: false,
        global_affiliate_percentage: 10,
        affiliates_disabled_reason: nil,
      })
    end
  end

  describe "#new_affiliate_props" do
    let(:seller) { create(:named_user) }
    let(:admin_for_seller) { create(:user, username: "adminforseller") }
    let(:pundit_user) { SellerContext.new(user: admin_for_seller, seller:) }

    before do
      create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    end

    let!(:product) { create(:product, name: "Test Product", user: seller) }

    it "returns products with enabled: false and default values" do
      props = described_class.new(pundit_user).new_affiliate_props

      expect(props[:products]).to be_an(Array)
      expect(props[:products].first).to include(
        enabled: false,
        fee_percent: nil,
        referral_url: "",
        destination_url: nil
      )
      expect(props[:affiliates_disabled_reason]).to be_nil
    end

    context "when seller has Brazilian Stripe account" do
      before do
        allow(seller).to receive(:has_brazilian_stripe_connect_account?).and_return(true)
      end

      it "returns the disabled reason" do
        props = described_class.new(pundit_user).new_affiliate_props

        expect(props[:affiliates_disabled_reason]).to eq("Affiliates with Brazilian Stripe accounts are not supported.")
      end
    end
  end

  describe "#edit_affiliate_props" do
    let(:seller) { create(:named_user) }
    let(:admin_for_seller) { create(:user, username: "adminforseller") }
    let(:pundit_user) { SellerContext.new(user: admin_for_seller, seller:) }
    let(:affiliate_user) { create(:affiliate_user) }
    let(:product) { create(:product, user: seller) }
    let!(:affiliate) { create(:direct_affiliate, seller:, affiliate_user:, products: [product]) }

    before do
      create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    end

    it "returns affiliate data with products" do
      props = described_class.new(pundit_user).edit_affiliate_props(affiliate)

      expect(props[:affiliate]).to be_a(Hash)
      expect(props[:affiliate][:id]).to eq(affiliate.external_id)
      expect(props[:affiliate][:email]).to eq(affiliate_user.email)
      expect(props[:affiliate][:products]).to be_an(Array)
      expect(props[:affiliates_disabled_reason]).to be_nil
    end

    context "when seller has Brazilian Stripe account" do
      before do
        allow(seller).to receive(:has_brazilian_stripe_connect_account?).and_return(true)
      end

      it "returns the disabled reason" do
        props = described_class.new(pundit_user).edit_affiliate_props(affiliate)

        expect(props[:affiliates_disabled_reason]).to eq("Affiliates with Brazilian Stripe accounts are not supported.")
      end
    end
  end
end
