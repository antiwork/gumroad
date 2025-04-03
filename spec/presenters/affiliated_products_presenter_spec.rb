# frozen_string_literal: true

require "spec_helper"

describe AffiliatedProductsPresenter do
  include CurrencyHelper

  describe "#affiliated_products_page_props", :vcr do
    # Users
    let(:creator_one) { create(:user, username: "creator1") }
    let(:creator_two) { create(:user, username: "creator2") }
    let(:affiliate_user) { create(:affiliate_user) }

    # Products
    let!(:creator_one_product_one) { create(:product, name: "Creator 1 Product 1", user: creator_one, price_cents: 1000, purchase_disabled_at: 1.minute.ago) }
    let!(:creator_one_product_two) { create(:physical_product, name: "Creator 1 Product 2", user: creator_one, price_cents: 2000) }
    let!(:creator_one_product_three) { create(:subscription_product, name: "Creator 1 Product 3", deleted_at: DateTime.current, user: creator_one, price_cents: 250) }
    let!(:creator_two_product_one) { create(:product, name: "Creator 2 Product 1", user: creator_two, price_cents: 5000) }
    let!(:creator_two_product_two) { create(:physical_product, name: "Creator 2 Product 2", user: creator_two, price_cents: 2500) }
    let!(:creator_two_product_three) { create(:subscription_product, name: "Creator 2 Product 3", user: creator_two, price_cents: 1000) }
    let!(:creator_two_product_four) { create(:product, name: "Creator 2 Product 4", user: creator_two, price_cents: 1000) }
    let!(:global_affiliate_eligible_product) { create(:product, :recommendable, user: creator_one) }
    let!(:global_affiliate_eligible_product_two) { create(:product, :recommendable, name: "PWYW Product", price_cents: 0, customizable_price: true) }
    let!(:another_product) { create(:product, name: "Another Product 1") }

    # Global affiliate
    let(:global_affiliate) { affiliate_user.global_affiliate }

    let!(:archived_affiliate) do
      affiliate = create(:direct_affiliate, affiliate_user:,
                                            seller: creator_one,
                                            affiliate_basis_points: 15_00,
                                            apply_to_all_products: true,
                                            deleted_at: 1.day.ago,
                                            created_at: 1.week.ago)
      create(:product_affiliate, affiliate:, product: creator_one_product_one, affiliate_basis_points: 15_00)
      create(:product_affiliate, affiliate:, product: creator_one_product_two, affiliate_basis_points: 15_00)
      create(:product_affiliate, affiliate:, product: creator_one_product_three, affiliate_basis_points: 15_00)
      affiliate
    end

    # Creator 1 affiliates
    let!(:direct_affiliate_one) do
      affiliate = create(:direct_affiliate, affiliate_user:,
                                            seller: creator_one,
                                            affiliate_basis_points: 15_00,
                                            apply_to_all_products: true,
                                            created_at: 1.week.ago)
      create(:product_affiliate, affiliate:, product: creator_one_product_one, affiliate_basis_points: 15_00)
      create(:product_affiliate, affiliate:, product: creator_one_product_two, affiliate_basis_points: 15_00)
      create(:product_affiliate, affiliate:, product: creator_one_product_three, affiliate_basis_points: 15_00)
      create(:product_affiliate, affiliate:, product: global_affiliate_eligible_product, affiliate_basis_points: 15_00)
      affiliate
    end

    # Creator 2 affiliates
    let!(:direct_affiliate_two) do
      affiliate = create(:direct_affiliate, affiliate_user:, seller: creator_two, created_at: 1.day.ago)
      create(:product_affiliate, affiliate:, product: creator_two_product_two, affiliate_basis_points: 500)
      create(:product_affiliate, affiliate:, product: creator_two_product_three, affiliate_basis_points: 2500)
      create(:product_affiliate, affiliate:, product: creator_two_product_four, affiliate_basis_points: 1000)
      affiliate
    end

    # Purchases
    let!(:purchase_one) { create(:purchase_in_progress, seller: creator_one, link: creator_one_product_one, affiliate: direct_affiliate_one) }
    let!(:purchase_two) { create(:purchase_in_progress, seller: creator_one, link: creator_one_product_one, affiliate: direct_affiliate_one) }
    let!(:purchase_three) { create(:purchase_in_progress, seller: creator_one, link: creator_one_product_three, affiliate: direct_affiliate_one, subscription: create(:subscription, link: creator_one_product_three), is_original_subscription_purchase: true) }
    let!(:purchase_four) { create(:purchase_in_progress, seller: creator_two, link: creator_two_product_one, affiliate: direct_affiliate_two) }
    let!(:purchase_five) { create(:purchase_in_progress, seller: creator_two, link: creator_two_product_two, affiliate: direct_affiliate_two, full_name: "John Doe", street_address: "123, Down the street", city: "Barnabasville", state: "CA", country: "United States", zip_code: "94114") }
    let!(:purchase_six) { create(:purchase_in_progress, seller: creator_two, link: creator_two_product_three, affiliate: direct_affiliate_two, subscription: create(:subscription, link: creator_two_product_three), is_original_subscription_purchase: true) }
    let!(:purchase_seven) { create(:purchase_in_progress, seller: creator_two, link: creator_two_product_three, affiliate: direct_affiliate_two, subscription: create(:subscription, link: creator_two_product_three), is_original_subscription_purchase: true) }
    let!(:purchase_eight) { create(:purchase_in_progress, seller: creator_two, link: creator_two_product_three, affiliate: direct_affiliate_two, subscription: create(:subscription, link: creator_two_product_three), is_original_subscription_purchase: true, chargeable: create(:chargeable)) }
    let!(:purchase_nine) { create(:purchase_in_progress, seller: creator_two, link: creator_two_product_four, affiliate: direct_affiliate_two) }
    let!(:purchase_ten) { create(:purchase_in_progress, link: another_product, affiliate: direct_affiliate_two) }
    let!(:purchase_eleven) { create(:purchase_in_progress, seller: global_affiliate_eligible_product.user, link: global_affiliate_eligible_product, affiliate: global_affiliate) }
    let!(:purchase_twelve) { create(:purchase_in_progress, seller: global_affiliate_eligible_product_two.user, link: global_affiliate_eligible_product_two, affiliate: global_affiliate) }
    let!(:purchase_thirteen) { create(:purchase_in_progress, seller: global_affiliate_eligible_product.user, link: global_affiliate_eligible_product, affiliate: direct_affiliate_one) }
    let(:successful_not_reversed_purchases) { [purchase_one, purchase_two, purchase_three, purchase_four, purchase_five, purchase_six, purchase_seven, purchase_eleven, purchase_twelve, purchase_thirteen] }
    let(:refunded_purchase) { purchase_eight }
    let(:chargedback_purchase) { purchase_nine }

    let(:all_product_details) do
      [
        { fee_percentage: 15,
          humanized_revenue: "$2.36",
          product_name: "Creator 1 Product 1",
          revenue: 236,
          sales_count: 2,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_one.referral_url_for_product(creator_one_product_one) },
        { fee_percentage: 15,
          humanized_revenue: "$0",
          product_name: "Creator 1 Product 2",
          revenue: 0,
          sales_count: 0,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_one.referral_url_for_product(creator_one_product_two) },
        { fee_percentage: 15,
          humanized_revenue: "$0.01",
          product_name: global_affiliate_eligible_product.name,
          revenue: 1,
          sales_count: 1,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_one.referral_url_for_product(global_affiliate_eligible_product) },
        { fee_percentage: 5,
          humanized_revenue: "$1.04",
          product_name: "Creator 2 Product 2",
          revenue: 104,
          sales_count: 1,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_two.referral_url_for_product(creator_two_product_two) },
        { fee_percentage: 25,
          humanized_revenue: "$3.94",
          product_name: "Creator 2 Product 3",
          revenue: 394,
          sales_count: 2,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_two.referral_url_for_product(creator_two_product_three) },
        { fee_percentage: 10,
          humanized_revenue: "$0",
          product_name: "Creator 2 Product 4",
          revenue: 0,
          sales_count: 0,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_two.referral_url_for_product(creator_two_product_four) },
        { fee_percentage: 10,
          humanized_revenue: "$0",
          product_name: global_affiliate_eligible_product.name,
          revenue: 0,
          sales_count: 0,
          affiliate_type: "global_affiliate",
          url: global_affiliate.referral_url_for_product(global_affiliate_eligible_product) },
        { fee_percentage: 10,
          humanized_revenue: "$0",
          product_name: global_affiliate_eligible_product_two.name,
          revenue: 0,
          sales_count: 0,
          affiliate_type: "global_affiliate",
          url: global_affiliate.referral_url_for_product(global_affiliate_eligible_product_two) }
      ]
    end

    before do
      purchases = successful_not_reversed_purchases + [refunded_purchase, chargedback_purchase]
      purchases.each do |purchase|
        purchase.process!
        purchase.update_balance_and_mark_successful!
      end

      refunded_purchase.refund_and_save!(nil)

      # chargeback purchase
      allow_any_instance_of(Purchase).to receive(:fight_chargeback).and_return(true)
      event_flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, chargedback_purchase.total_transaction_cents)
      event = build(:charge_event_dispute_formalized, charge_id: chargedback_purchase.stripe_transaction_id, flow_of_funds: event_flow_of_funds)
      chargedback_purchase.handle_event_dispute_formalized!(event)
      chargedback_purchase.reload

      # failed purchase
      create(:purchase_in_progress, seller: creator_one, link: creator_one_product_one, affiliate: direct_affiliate_one).mark_failed!

      # collaborator (excluded from result)
      create(:product, :is_collab, user: affiliate_user)
    end

    it "returns affiliated products details, stats, and global affiliates data" do
      props = described_class.new(affiliate_user).affiliated_products_page_props
      stats = {
        total_revenue: successful_not_reversed_purchases.sum(&:affiliate_credit_cents),
        total_sales: 10,
        total_products: 7,
        total_affiliated_creators: 3,
      }
      global_affiliates_data = {
        global_affiliate_id: global_affiliate.external_id_numeric,
        global_affiliate_sales: formatted_dollar_amount(purchase_eleven.affiliate_credit_cents, with_currency: false),
        cookie_expiry_days: GlobalAffiliate::AFFILIATE_COOKIE_LIFETIME_DAYS,
        affiliate_query_param: Affiliate::SHORT_QUERY_PARAM,
      }

      expect(props[:affiliated_products]).to match_array all_product_details
      expect(props[:stats]).to eq stats
      expect(props[:global_affiliates_data]).to eq global_affiliates_data
      expect(props[:discover_url]).to eq UrlService.discover_domain_with_protocol
      expect(props[:affiliates_disabled_reason]).to be nil
    end

    it "returns affiliates_disabled_reason if using Brazilian Stripe Connect account" do
      brazilian_stripe_account = create(:merchant_account_stripe_connect, user: affiliate_user, country: "BR")
      affiliate_user.update!(check_merchant_account_is_linked: true)
      expect(affiliate_user.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

      props = described_class.new(affiliate_user).affiliated_products_page_props
      expect(props[:affiliates_disabled_reason]).to eq "Affiliates with Brazilian Stripe accounts are not supported."
    end

    context "when there is a search query" do
      context "when the query exactly matches an affiliated product" do
        let(:query) { "Creator 1 Product 1" }

        it "returns only the matching product" do
          props = described_class.new(affiliate_user, query:).affiliated_products_page_props
          products_details = [
            { fee_percentage: 15,
              humanized_revenue: "$2.36",
              product_name: "Creator 1 Product 1",
              revenue: 236,
              sales_count: 2,
              affiliate_type: "direct_affiliate",
              url: direct_affiliate_one.referral_url_for_product(creator_one_product_one) }
          ]
          expect(props[:affiliated_products]).to match_array products_details
        end
      end

      context "when the query partially matches an affiliated product" do
        let(:query) { "Creator 1" }

        it "returns all matching products" do
          props = described_class.new(affiliate_user, query:).affiliated_products_page_props
          products_details = [
            { fee_percentage: 15,
              humanized_revenue: "$2.36",
              product_name: "Creator 1 Product 1",
              revenue: 236,
              sales_count: 2,
              affiliate_type: "direct_affiliate",
              url: direct_affiliate_one.referral_url_for_product(creator_one_product_one) },
            { fee_percentage: 15,
              humanized_revenue: "$0",
              product_name: "Creator 1 Product 2",
              revenue: 0,
              sales_count: 0,
              affiliate_type: "direct_affiliate",
              url: direct_affiliate_one.referral_url_for_product(creator_one_product_two) }
          ]
          expect(props[:affiliated_products]).to match_array products_details
        end
      end

      context "when the query does not match any affiliated products" do
        let(:query) { "Creator Nobody" }

        it "returns an empty array" do
          props = described_class.new(affiliate_user, query:).affiliated_products_page_props
          expect(props[:affiliated_products]).to be_empty
        end
      end
    end

    context "supports pagination" do
      before { stub_const("AffiliatedProductsPresenter::PER_PAGE", 5) }

      it "returns page 1 by default" do
        props = described_class.new(affiliate_user).affiliated_products_page_props
        expect(props[:affiliated_products].count).to eq 5
        expect(props[:affiliated_products]).to match_array all_product_details.take(5)
        pagination = props[:pagination]
        expect(pagination[:page]).to eq(1)
        expect(pagination[:pages]).to eq(2)
      end

      it "returns the specified page if in range" do
        props = described_class.new(affiliate_user, page: 2).affiliated_products_page_props
        expect(props[:affiliated_products].count).to eq 3
        expect(props[:affiliated_products]).to match_array all_product_details.drop(5)
        pagination = props[:pagination]
        expect(pagination[:page]).to eq(2)
        expect(pagination[:pages]).to eq(2)
      end

      it "raises an error if out of range" do
        expect do
          described_class.new(affiliate_user, page: 3).affiliated_products_page_props
        end.to raise_error(Pagy::OverflowError)
      end
    end

    context "when sorting" do
      before { stub_const("AffiliatedProductsPresenter::PER_PAGE", 1) }

      it "returns the products sorted by created timestamp by default" do
        props = described_class.new(affiliate_user).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 15,
          humanized_revenue: "$2.36",
          product_name: "Creator 1 Product 1",
          revenue: 236,
          sales_count: 2,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_one.referral_url_for_product(creator_one_product_one)
        })

        props = described_class.new(affiliate_user, page: 2).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 15,
          humanized_revenue: "$0",
          product_name: "Creator 1 Product 2",
          revenue: 0,
          sales_count: 0,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_one.referral_url_for_product(creator_one_product_two)
        })
      end

      it "returns the products sorted by revenue when specified" do
        props = described_class.new(affiliate_user, sort: { key: "revenue", direction: "asc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 15,
          humanized_revenue: "$0",
          product_name: "Creator 1 Product 2",
          revenue: 0,
          sales_count: 0,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_one.referral_url_for_product(creator_one_product_two)
        })

        props = described_class.new(affiliate_user, page: 2, sort: { key: "revenue", direction: "asc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 10,
          humanized_revenue: "$0",
          product_name: "Creator 2 Product 4",
          revenue: 0,
          sales_count: 0,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_two.referral_url_for_product(creator_two_product_four)
        })

        props = described_class.new(affiliate_user, sort: { key: "revenue", direction: "desc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 25,
          humanized_revenue: "$3.94",
          product_name: "Creator 2 Product 3",
          revenue: 394,
          sales_count: 2,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_two.referral_url_for_product(creator_two_product_three)
        })

        props = described_class.new(affiliate_user, page: 2, sort: { key: "revenue", direction: "desc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 15,
          humanized_revenue: "$2.36",
          product_name: "Creator 1 Product 1",
          revenue: 236,
          sales_count: 2,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_one.referral_url_for_product(creator_one_product_one)
        })
      end

      it "returns the products sorted by sales when specified" do
        props = described_class.new(affiliate_user, sort: { key: "sales_count", direction: "asc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 15,
          humanized_revenue: "$0",
          product_name: "Creator 1 Product 2",
          revenue: 0,
          sales_count: 0,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_one.referral_url_for_product(creator_one_product_two)
        })

        props = described_class.new(affiliate_user, page: 2, sort: { key: "sales_count", direction: "asc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 10,
          humanized_revenue: "$0",
          product_name: "Creator 2 Product 4",
          revenue: 0,
          sales_count: 0,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_two.referral_url_for_product(creator_two_product_four)
        })

        props = described_class.new(affiliate_user, sort: { key: "sales_count", direction: "desc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 15,
          humanized_revenue: "$2.36",
          product_name: "Creator 1 Product 1",
          revenue: 236,
          sales_count: 2,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_one.referral_url_for_product(creator_one_product_one)
        })

        props = described_class.new(affiliate_user, page: 2, sort: { key: "sales_count", direction: "desc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 25,
          humanized_revenue: "$3.94",
          product_name: "Creator 2 Product 3",
          revenue: 394,
          sales_count: 2,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_two.referral_url_for_product(creator_two_product_three)
        })
      end

      it "returns the products sorted by name when specified" do
        props = described_class.new(affiliate_user, sort: { key: "product_name", direction: "asc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 15,
          humanized_revenue: "$2.36",
          product_name: "Creator 1 Product 1",
          revenue: 236,
          sales_count: 2,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_one.referral_url_for_product(creator_one_product_one)
        })

        props = described_class.new(affiliate_user, page: 2, sort: { key: "product_name", direction: "asc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 15,
          humanized_revenue: "$0",
          product_name: "Creator 1 Product 2",
          revenue: 0,
          sales_count: 0,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_one.referral_url_for_product(creator_one_product_two)
        })

        props = described_class.new(affiliate_user, sort: { key: "product_name", direction: "desc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly({
                                                                 fee_percentage: 15,
                                                                 humanized_revenue: "$0.01",
                                                                 product_name: global_affiliate_eligible_product.name,
                                                                 revenue: 1,
                                                                 sales_count: 1,
                                                                 affiliate_type: "direct_affiliate",
                                                                 url: direct_affiliate_one.referral_url_for_product(global_affiliate_eligible_product)
                                                               })

        props = described_class.new(affiliate_user, page: 2, sort: { key: "product_name", direction: "desc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly({
                                                                 fee_percentage: 10,
                                                                 humanized_revenue: "$0",
                                                                 product_name: global_affiliate_eligible_product.name,
                                                                 revenue: 0,
                                                                 sales_count: 0,
                                                                 affiliate_type: "global_affiliate",
                                                                 url: global_affiliate.referral_url_for_product(global_affiliate_eligible_product),
                                                               })
      end

      it "returns the products sorted by commission when specified" do
        props = described_class.new(affiliate_user, sort: { key: "commission", direction: "asc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 5,
          humanized_revenue: "$1.04",
          product_name: "Creator 2 Product 2",
          revenue: 104,
          sales_count: 1,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_two.referral_url_for_product(creator_two_product_two)
        })

        props = described_class.new(affiliate_user, page: 2, sort: { key: "commission", direction: "asc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 10,
          humanized_revenue: "$0",
          product_name: "Creator 2 Product 4",
          revenue: 0,
          sales_count: 0,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_two.referral_url_for_product(creator_two_product_four)
        })

        props = described_class.new(affiliate_user, sort: { key: "commission", direction: "desc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 25,
          humanized_revenue: "$3.94",
          product_name: "Creator 2 Product 3",
          revenue: 394,
          sales_count: 2,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_two.referral_url_for_product(creator_two_product_three)
        })

        props = described_class.new(affiliate_user, page: 2, sort: { key: "commission", direction: "desc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly(
        {
          fee_percentage: 15,
          humanized_revenue: "$2.36",
          product_name: "Creator 1 Product 1",
          revenue: 236,
          sales_count: 2,
          affiliate_type: "direct_affiliate",
          url: direct_affiliate_one.referral_url_for_product(creator_one_product_one)
        })
      end

      it "returns the products sorted by created timestamp when the sort field is invalid" do
        props = described_class.new(affiliate_user, sort: { key: "invalid", direction: "asc" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly all_product_details.first
      end

      it "returns the products in ascending order when the sort direction is invalid" do
        props = described_class.new(affiliate_user, sort: { key: "revenue", direction: "desc; invalid or nefarious SQL" }).affiliated_products_page_props
        expect(props[:affiliated_products]).to contain_exactly({
                                                                 fee_percentage: 15,
                                                                 humanized_revenue: "$0",
                                                                 product_name: "Creator 1 Product 2",
                                                                 revenue: 0,
                                                                 sales_count: 0,
                                                                 affiliate_type: "direct_affiliate",
                                                                 url: direct_affiliate_one.referral_url_for_product(creator_one_product_two)
                                                               })
      end
    end
  end

  describe "#archived_tab_visible" do
    let(:seller) { create(:user, username: "seller1") }
    let!(:product) { create(:product, archived: true, user: seller) }

    it "returns archived products present and feature active" do
      expect(described_class.new(seller).affiliated_products_page_props[:archived_tab_visible]).to eq(true)
      product.destroy!
      expect(described_class.new(seller).affiliated_products_page_props[:archived_tab_visible]).to eq(false)
    end
  end
end
