# frozen_string_literal: true

require "spec_helper"

describe AffiliatedProductsPresenter do
  include CurrencyHelper

  # The removal keys (`affiliate_id`, `seller_name`) are asserted on their own below; the
  # per-product expectations here are about the listing itself.
  def listed_products(props)
    props[:affiliated_products].map { _1.except(:affiliate_id, :seller_name) }
  end

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
        # total_revenue is a gross figure: it sums every affiliate credit the
        # user has, including the ones for the refunded and chargedback
        # purchases, so it lines up with total_sales below (which counts the
        # same rows). See User#affiliate_credits_total_revenue_cents.
        total_revenue: (successful_not_reversed_purchases + [refunded_purchase, chargedback_purchase]).sum(&:affiliate_credit_cents),
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

      expect(listed_products(props)).to match_array all_product_details
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
          expect(listed_products(props)).to match_array products_details
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
          expect(listed_products(props)).to match_array products_details
        end
      end

      context "when the query does not match any affiliated products" do
        let(:query) { "Creator Nobody" }

        it "returns an empty array" do
          props = described_class.new(affiliate_user, query:).affiliated_products_page_props
          expect(listed_products(props)).to be_empty
        end
      end
    end

    context "supports pagination" do
      before { stub_const("AffiliatedProductsPresenter::PER_PAGE", 5) }

      it "returns page 1 by default" do
        props = described_class.new(affiliate_user).affiliated_products_page_props
        expect(props[:affiliated_products].count).to eq 5
        expect(listed_products(props)).to match_array all_product_details.take(5)
        pagination = props[:pagination]
        expect(pagination[:page]).to eq(1)
        expect(pagination[:pages]).to eq(2)
      end

      it "returns the specified page if in range" do
        props = described_class.new(affiliate_user, page: 2).affiliated_products_page_props
        expect(props[:affiliated_products].count).to eq 3
        expect(listed_products(props)).to match_array all_product_details.drop(5)
        pagination = props[:pagination]
        expect(pagination[:page]).to eq(2)
        expect(pagination[:pages]).to eq(2)
      end

      it "returns the last page if out of range" do
        props = described_class.new(affiliate_user, page: 3).affiliated_products_page_props
        pagination = props[:pagination]
        expect(pagination[:page]).to eq(2)
        expect(pagination[:pages]).to eq(2)
      end

      it "computes the pagination total without running the grouped affiliate_credits join" do
        # The page total used to come from pagy's COUNT(*) OVER () on the full
        # grouped relation, re-running the expensive affiliate_credits join a
        # second time per request. The count now comes from a plain
        # COUNT(DISTINCT link_id, affiliate_id) on the un-grouped scope, so no
        # counting query should reference affiliate_credits.
        counting_queries_with_credits_join = []
        callback = lambda do |_name, _start, _finish, _id, payload|
          sql = payload[:sql]
          if sql.match?(/\bCOUNT\b/i) && sql.include?("affiliate_credits") && !sql.include?("COUNT(DISTINCT affiliate_credits")
            counting_queries_with_credits_join << sql
          end
        end

        props = nil
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          props = described_class.new(affiliate_user).affiliated_products_page_props
        end

        expect(props[:pagination][:pages]).to eq(2)
        expect(counting_queries_with_credits_join.grep(/OVER \(\)/)).to be_empty
      end

      it "keeps the pagination total in sync with the grouped rows when duplicate product-affiliate pairs exist" do
        # Existing duplicate rows remain until a later cleanup adds the unique index.
        duplicate_attributes = {
          affiliate_id: direct_affiliate_one.id,
          link_id: creator_one_product_one.id,
          affiliate_basis_points: 25_00,
          created_at: Time.current,
          updated_at: Time.current
        }
        ProductAffiliate.insert!(duplicate_attributes)

        grouped_row_count = described_class.new(affiliate_user).send(:affiliated_products).length

        props = described_class.new(affiliate_user).affiliated_products_page_props
        expected_pages = (grouped_row_count.to_f / AffiliatedProductsPresenter::PER_PAGE).ceil
        expect(props[:pagination][:pages]).to eq(expected_pages)

        last_page_props = described_class.new(affiliate_user, page: expected_pages).affiliated_products_page_props
        expected_last_page_size = grouped_row_count - (expected_pages - 1) * AffiliatedProductsPresenter::PER_PAGE
        expect(last_page_props[:affiliated_products].count).to eq(expected_last_page_size)
      end

      it "counts pairs whose basis-points grouping key is NULL" do
        # The basis-points columns are nullable at the database level
        # (presence is only enforced by model validations), and MySQL's
        # multi-column COUNT(DISTINCT ...) silently drops tuples containing a
        # NULL argument while GROUP BY keeps the NULL-keyed group. With a NULL
        # link-level value and a zero affiliate-level value, the grouping
        # expression (NULL || 0) evaluates to NULL in MySQL, so without the
        # COALESCE wrapper this pair would vanish from the page total and the
        # last page could become unreachable.
        pair = ProductAffiliate.find_by(affiliate: direct_affiliate_one, product: creator_one_product_one)
        pair.update_column(:affiliate_basis_points, nil)
        direct_affiliate_one.update_column(:affiliate_basis_points, 0)

        grouped_row_count = described_class.new(affiliate_user).send(:affiliated_products).length

        props = described_class.new(affiliate_user).affiliated_products_page_props
        expected_pages = (grouped_row_count.to_f / AffiliatedProductsPresenter::PER_PAGE).ceil
        expect(props[:pagination][:pages]).to eq(expected_pages)

        last_page_props = described_class.new(affiliate_user, page: expected_pages).affiliated_products_page_props
        expected_last_page_size = grouped_row_count - (expected_pages - 1) * AffiliatedProductsPresenter::PER_PAGE
        expect(last_page_props[:affiliated_products].count).to eq(expected_last_page_size)
      end
    end

    context "when sorting" do
      before { stub_const("AffiliatedProductsPresenter::PER_PAGE", 1) }

      it "returns the products sorted by created timestamp by default" do
        props = described_class.new(affiliate_user).affiliated_products_page_props
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly({
                                                            fee_percentage: 15,
                                                            humanized_revenue: "$0.01",
                                                            product_name: global_affiliate_eligible_product.name,
                                                            revenue: 1,
                                                            sales_count: 1,
                                                            affiliate_type: "direct_affiliate",
                                                            url: direct_affiliate_one.referral_url_for_product(global_affiliate_eligible_product)
                                                          })

        props = described_class.new(affiliate_user, page: 2, sort: { key: "product_name", direction: "desc" }).affiliated_products_page_props
        expect(listed_products(props)).to contain_exactly({
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly(
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
        expect(listed_products(props)).to contain_exactly all_product_details.first
      end

      it "returns the products in ascending order when the sort direction is invalid" do
        props = described_class.new(affiliate_user, sort: { key: "revenue", direction: "desc; invalid or nefarious SQL" }).affiliated_products_page_props
        expect(listed_products(props)).to contain_exactly({
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

  describe "#affiliated_products_page_props when the global affiliate has been deleted" do
    it "returns nil for global affiliate fields without raising" do
      user = create(:affiliate_user)
      user.global_affiliate.update!(deleted_at: Time.current)
      user.reload

      props = described_class.new(user).affiliated_products_page_props

      expect(props[:global_affiliates_data][:global_affiliate_id]).to be_nil
      expect(props[:global_affiliates_data][:global_affiliate_sales]).to be_nil
      expect(props[:global_affiliates_data][:cookie_expiry_days]).to eq GlobalAffiliate::AFFILIATE_COOKIE_LIFETIME_DAYS
      expect(props[:global_affiliates_data][:affiliate_query_param]).to eq Affiliate::SHORT_QUERY_PARAM
    end
  end

  # Kept out of the `:vcr` block above: nothing here needs a purchase, so these
  # examples do not have to sit behind that block's Stripe cassettes.
  describe "#affiliated_products_page_props removal keys" do
    let(:affiliate_user) { create(:affiliate_user) }
    let(:creator) { create(:user, username: "removalcreator") }
    let!(:product) { create(:product, name: "Removal Product", user: creator) }
    # The global row is wired up directly rather than through the `:recommendable`
    # trait, which creates a purchase (and so needs this file's Stripe cassettes).
    let!(:global_product) { create(:product, name: "Global Product") }
    let!(:global_row) { create(:product_affiliate, affiliate: affiliate_user.global_affiliate, product: global_product, affiliate_basis_points: 10_00) }

    let!(:direct_affiliate) do
      affiliate = create(:direct_affiliate, affiliate_user:, seller: creator, affiliate_basis_points: 15_00)
      create(:product_affiliate, affiliate:, product:, affiliate_basis_points: 15_00)
      affiliate
    end

    it "marks direct affiliations as removable and global ones as not" do
      props = described_class.new(affiliate_user, can_remove_affiliations: true).affiliated_products_page_props

      direct = props[:affiliated_products].find { _1[:affiliate_type] == "direct_affiliate" }
      expect(direct[:affiliate_id]).to eq(direct_affiliate.external_id)
      expect(direct[:seller_name]).to eq(creator.name_or_username)

      global = props[:affiliated_products].find { _1[:affiliate_type] == "global_affiliate" }
      expect(global[:product_name]).to eq("Global Product")
      expect(global[:affiliate_id]).to be_nil
      expect(global[:seller_name]).to be_nil
    end

    it "marks nothing removable for a viewer who cannot end affiliations" do
      props = described_class.new(affiliate_user).affiliated_products_page_props

      expect(props[:affiliated_products]).to be_present
      expect(props[:affiliated_products].map { _1[:affiliate_id] }).to all(be_nil)
    end

    it "counts only creators the user is still affiliated with" do
      expect(described_class.new(affiliate_user).affiliated_products_page_props[:stats][:total_affiliated_creators]).to eq(2)

      direct_affiliate.mark_deleted!

      props = described_class.new(affiliate_user).affiliated_products_page_props
      expect(props[:stats][:total_affiliated_creators]).to eq(1)
      expect(props[:affiliated_products].map { _1[:product_name] }).not_to include("Removal Product")
    end

    it "reports account-wide stats while a search narrows the listing" do
      props = described_class.new(affiliate_user, query: "Removal").affiliated_products_page_props

      expect(props[:affiliated_products].map { _1[:product_name] }).to eq(["Removal Product"])
      expect(props[:stats][:total_products]).to eq(2)
      expect(props[:stats][:total_affiliated_creators]).to eq(2)
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

  describe "revenue stats" do
    let(:user) { create(:affiliate_user) }

    it "reports total_revenue as the gross sum of every credit, including refunded and chargebacked ones" do
      # The headline revenue figure is deliberately gross: it counts the same
      # rows the "Total sales" stat counts, so the two numbers on the page
      # reconcile with each other. Refunds, chargebacks and missing balance
      # rows do not remove a credit from it.
      # `purchase_in_progress` rather than the bare purchase factory: a plain
      # `create(:purchase)` runs the charge validations, which is unrelated
      # machinery for a spec about summing credit rows.
      credit = ->(cents) do
        create(:affiliate_credit, affiliate_user: user, amount_cents: cents,
                                  purchase: create(:purchase_in_progress))
      end

      plain_credit = credit.call(500)
      partially_refunded_credit = credit.call(300)
      # This flag is the column the old partial-refund adjustment joined
      # purchases to read. Setting it is what proves that adjustment no longer
      # runs: under the old shape this credit's amount was counted twice.
      partially_refunded_credit.purchase.update_column(:stripe_partially_refunded, true)
      fully_refunded_credit = credit.call(700)
      chargebacked_credit = credit.call(900)

      # The balance ids are what mark a credit as refunded or charged back. They
      # are set directly rather than through the balance factory because this
      # spec only cares that the ids are present — which balance row they point
      # at makes no difference to a sum that ignores them.
      fully_refunded_credit.update_column(:affiliate_credit_refund_balance_id, 1)
      chargebacked_credit.update_column(:affiliate_credit_chargeback_balance_id, 2)

      props = described_class.new(user).affiliated_products_page_props

      expect(props[:stats][:total_revenue]).to eq 500 + 300 + 700 + 900
      # Same population as the sales count beside it.
      expect(props[:stats][:total_sales]).to eq 4
      expect([plain_credit, partially_refunded_credit, fully_refunded_credit,
              chargebacked_credit].sum(&:amount_cents)).to eq props[:stats][:total_revenue]
      # Guard against the old `paid`-scoped shape quietly coming back: under it
      # the refunded and chargebacked credits would have been excluded.
      expect(user.affiliate_credits.paid.sum(:amount_cents)).to be < props[:stats][:total_revenue]
    end

    it "does not run the partial-refund adjustment query for the revenue stat" do
      expect(user).not_to receive(:affiliate_credit_sum_from_scope)

      described_class.new(user).affiliated_products_page_props
    end

    it "caches the raw global affiliate earnings but formats them fresh on every request" do
      # Only the expensive cents sum is cached; the currency formatting runs
      # each time so a changed display preference is reflected immediately.
      expect_any_instance_of(GlobalAffiliate).to receive(:total_cents_earned).once.with(timeout_ms: anything).and_return(1234)

      expect(described_class.new(user).affiliated_products_page_props[:global_affiliates_data][:global_affiliate_sales]).to eq "$12.34"
      expect(described_class.new(user).affiliated_products_page_props[:global_affiliates_data][:global_affiliate_sales]).to eq "$12.34"

      # A formatting-preference change takes effect without waiting for the
      # cached cents to expire.
      allow_any_instance_of(User).to receive(:should_be_shown_currencies_always?).and_return(true)
      expect(described_class.new(user).affiliated_products_page_props[:global_affiliates_data][:global_affiliate_sales]).to eq "$12.34 USD"
    end

    it "never runs the unbounded lifetime earnings sum inside the request" do
      # The whole point of the background path: an in-request computation must
      # always carry a statement timeout so a heavy affiliate cannot stall the
      # page until the request ceiling kills it. The argument constraint is what
      # enforces that: a call without the timeout would fail this expectation as
      # an unexpected-arguments error rather than satisfying it.
      expect_any_instance_of(GlobalAffiliate).to receive(:total_cents_earned).with(timeout_ms: AffiliateEarningsCache::REQUEST_TIMEOUT_MS).and_return(0)

      described_class.new(user).affiliated_products_page_props
    end

    it "reports the earnings as not yet available, instead of zero, when the sum times out" do
      # MySQL raises error 3024 for a MAX_EXECUTION_TIME abort, which Rails
      # surfaces as StatementTimeout.
      allow_any_instance_of(GlobalAffiliate).to receive(:total_cents_earned).with(timeout_ms: anything)
        .and_raise(ActiveRecord::StatementTimeout.new("maximum statement execution time exceeded"))

      props = nil
      expect do
        props = described_class.new(user).affiliated_products_page_props
      end.to change { RefreshAffiliateEarningsJob.jobs.size }.by(1)

      expect(props[:global_affiliates_data][:global_affiliate_sales]).to be_nil
    end

    it "reports revenue per user" do
      other_user = create(:affiliate_user)
      expect(user).to receive(:affiliate_credits_total_revenue_cents).and_return(100)
      expect(other_user).to receive(:affiliate_credits_total_revenue_cents).and_return(200)

      expect(described_class.new(user).affiliated_products_page_props[:stats][:total_revenue]).to eq 100
      expect(described_class.new(other_user).affiliated_products_page_props[:stats][:total_revenue]).to eq 200
    end
  end
end
