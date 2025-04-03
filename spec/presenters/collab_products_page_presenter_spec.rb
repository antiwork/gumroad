# frozen_string_literal: true

require "spec_helper"

describe CollabProductsPagePresenter, :vcr do
  include Rails.application.routes.url_helpers

  # User is a collaborator for two other sellers
  let(:user) { create(:user) }
  let(:pundit_user) { SellerContext.new(user:, seller: user) }

  let(:seller_1) { create(:user) }
  let(:seller_1_collaborator) { create(:collaborator, seller: seller_1, affiliate_user: user) }

  let(:seller_2) { create(:user) }
  let(:seller_2_collaborator) { create(:collaborator, seller: seller_2, affiliate_user: user) }

  # Products

  # 1. Owned by user
  let!(:collab_1) { create(:product, :is_collab, user:, price_cents: 15_00, collaborator_cut: 50_00, created_at: 1.month.ago) }
  let!(:membership_collab_1) { create(:membership_product_with_preset_tiered_pricing, :is_collab, user:, collaborator_cut: 50_00, created_at: 2.months.ago) }

  # 2. Owned by others
  let!(:collab_2) { create(:product, :is_collab, user: seller_1, collaborator_cut: 25_00, collaborator: seller_1_collaborator, created_at: 3.months.ago) }
  let!(:collab_3) { create(:product, :is_collab, user: seller_2, collaborator_cut: 50_00, collaborator: seller_2_collaborator, created_at: 4.months.ago) } # no purchases
  let!(:membership_collab_2) { create(:membership_product_with_preset_tiered_pricing, :is_collab, user: seller_2, collaborator_cut: 25_00, collaborator: seller_2_collaborator, created_at: 5.months.ago) }

  # 3. Non-collab
  let!(:non_collab_product) { create(:product, user:) }
  let!(:affiliate_product) { create(:product, user:) }
  let!(:affiliate) { create(:direct_affiliate, seller: user, products: [affiliate_product]) }

  # Purchases

  # 1. For collabs
  let(:collab_1_purchase_1) { create(:purchase_in_progress, seller: user, link: collab_1, affiliate: collab_1.collaborator) }
  let(:collab_1_purchase_2) { create(:purchase_in_progress, seller: user, link: collab_1, affiliate: collab_1.collaborator) }
  let(:collab_1_purchase_3) { create(:purchase_in_progress, seller: user, link: collab_1, affiliate: collab_1.collaborator) }
  let(:collab_2_purchase_1) { create(:purchase_in_progress, seller: seller_1, link: collab_2, affiliate: collab_2.collaborator) }
  let(:collab_2_purchase_2) { create(:purchase_in_progress, seller: seller_1, link: collab_2, affiliate: collab_2.collaborator) }
  let(:collab_2_purchase_3) { create(:purchase_in_progress, seller: seller_1, link: collab_2, affiliate: collab_2.collaborator) }

  let(:membership_collab_1_purchase_1) do
    tier = membership_collab_1.tiers.first
    create(:membership_purchase, purchase_state: "in_progress", seller: user,
                                 link: membership_collab_1, price_cents: tier.prices.first.price_cents, # $3
                                 affiliate: membership_collab_1.collaborator, tier:)
  end
  let(:membership_collab_1_purchase_2) do
    tier = membership_collab_1.tiers.last
    create(:membership_purchase, purchase_state: "in_progress", seller: user,
                                 link: membership_collab_1, price_cents: tier.prices.first.price_cents, # $5
                                 affiliate: membership_collab_1.collaborator, tier:)
  end
  let(:membership_collab_2_purchase_1) do
    tier = membership_collab_2.tiers.last
    create(:membership_purchase, purchase_state: "in_progress", seller: seller_2,
                                 link: membership_collab_2, price_cents: tier.prices.first.price_cents, # $5
                                 affiliate: membership_collab_2.collaborator, tier:)
  end

  # 2. For non-collabs
  let(:non_collab_purchase) { create(:purchase_in_progress, seller: user, link: non_collab_product) }
  let(:affiliate_purchase) { create(:purchase_in_progress, seller: user, link: affiliate_product, affiliate:) }

  let(:successful_not_reversed_purchases) do
    [
      collab_1_purchase_1,
      collab_1_purchase_2,
      collab_1_purchase_3,
      collab_2_purchase_1,
      membership_collab_1_purchase_1,
      membership_collab_1_purchase_2,
      membership_collab_2_purchase_1,
    ]
  end

  let(:chargedback_purchase) { collab_2_purchase_2 }
  let(:failed_purchase) { collab_2_purchase_3 }

  let(:collab_1_revenue) do
    [collab_1_purchase_1, collab_1_purchase_2, collab_1_purchase_3].sum do |p| # 3 successful
      p.displayed_price_cents - (p.affiliate_credit_cents + p.affiliate_credit.fee_cents)
    end
  end
  let(:collab_2_revenue) { collab_2_purchase_1.affiliate_credit_cents + collab_2_purchase_1.affiliate_credit.fee_cents } # 1 successful + 1 chargeback + 1 failed
  let(:collab_3_revenue) { 0 }
  let(:membership_collab_1_revenue) do
    [membership_collab_1_purchase_1, membership_collab_1_purchase_2].sum do |p| # 2 successful
      p.displayed_price_cents - (p.affiliate_credit_cents + p.affiliate_credit.fee_cents)
    end
  end
  let(:membership_collab_2_revenue) { membership_collab_2_purchase_1.affiliate_credit_cents + membership_collab_2_purchase_1.affiliate_credit.fee_cents } # 1 successful
  let(:total_revenue) { collab_1_revenue + collab_2_revenue + collab_3_revenue + membership_collab_1_revenue + membership_collab_2_revenue }

  let(:products_props) do
    [
      {
        "id" => collab_1.id,
        "edit_url" => edit_link_path(collab_1),
        "name" => collab_1.name,
        "permalink" => collab_1.unique_permalink,
        "price_formatted" => collab_1.price_formatted_including_rental_verbose,
        "revenue" => collab_1_revenue,
        "thumbnail" => collab_1.thumbnail&.alive&.as_json,
        "display_price_cents" => collab_1.display_price_cents,
        "url" => collab_1.long_url,
        "url_without_protocol" => collab_1.long_url(include_protocol: false),
        "has_duration" => collab_1.duration_in_months.present?,
        "cut" => collab_1.percentage_revenue_cut_for_user(user),
        "can_edit" => true,
        "successful_sales_count" => 3,
        "remaining_for_sale_count" => nil,
        "monthly_recurring_revenue" => 0.0,
        "revenue_pending" => 0.0,
        "total_usd_cents" => 4500,
      },
      {
        "id" => collab_2.id,
        "edit_url" => edit_link_path(collab_2),
        "name" => collab_2.name,
        "permalink" => collab_2.unique_permalink,
        "price_formatted" => collab_2.price_formatted_including_rental_verbose,
        "revenue" => collab_2_revenue,
        "thumbnail" => collab_2.thumbnail&.alive&.as_json,
        "display_price_cents" => collab_2.display_price_cents,
        "url" => collab_2.long_url,
        "url_without_protocol" => collab_2.long_url(include_protocol: false),
        "has_duration" => collab_2.duration_in_months.present?,
        "cut" => collab_2.percentage_revenue_cut_for_user(user),
        "can_edit" => true,
        "successful_sales_count" => 1,
        "remaining_for_sale_count" => nil,
        "monthly_recurring_revenue" => 0.0,
        "revenue_pending" => 0.0,
        "total_usd_cents" => 100,
      },
      {
        "id" => collab_3.id,
        "edit_url" => edit_link_path(collab_3),
        "name" => collab_3.name,
        "permalink" => collab_3.unique_permalink,
        "price_formatted" => collab_3.price_formatted_including_rental_verbose,
        "revenue" => collab_3_revenue,
        "thumbnail" => collab_3.thumbnail&.alive&.as_json,
        "display_price_cents" => collab_3.display_price_cents,
        "url" => collab_3.long_url,
        "url_without_protocol" => collab_3.long_url(include_protocol: false),
        "has_duration" => collab_3.duration_in_months.present?,
        "cut" => collab_3.percentage_revenue_cut_for_user(user),
        "can_edit" => true,
        "successful_sales_count" => 0,
        "remaining_for_sale_count" => nil,
        "monthly_recurring_revenue" => 0.0,
        "revenue_pending" => 0.0,
        "total_usd_cents" => 0,
      },
    ]
  end

  let(:memberships_props) do
    [
      {
        "id" => membership_collab_1.id,
        "edit_url" => edit_link_path(membership_collab_1),
        "name" => membership_collab_1.name,
        "permalink" => membership_collab_1.unique_permalink,
        "price_formatted" => membership_collab_1.price_formatted_including_rental_verbose,
        "revenue" => membership_collab_1_revenue,
        "thumbnail" => membership_collab_1.thumbnail&.alive&.as_json,
        "display_price_cents" => membership_collab_1.display_price_cents,
        "url" => membership_collab_1.long_url,
        "url_without_protocol" => membership_collab_1.long_url(include_protocol: false),
        "has_duration" => membership_collab_1.duration_in_months.present?,
        "cut" => membership_collab_1.percentage_revenue_cut_for_user(user),
        "can_edit" => true,
        "successful_sales_count" => 2,
        "remaining_for_sale_count" => nil,
        "monthly_recurring_revenue" => membership_collab_1.monthly_recurring_revenue,
        "revenue_pending" => 0.0,
        "total_usd_cents" => 800,
      },
      {
        "id" => membership_collab_2.id,
        "edit_url" => edit_link_path(membership_collab_2),
        "name" => membership_collab_2.name,
        "permalink" => membership_collab_2.unique_permalink,
        "price_formatted" => membership_collab_2.price_formatted_including_rental_verbose,
        "revenue" => membership_collab_2_revenue,
        "thumbnail" => membership_collab_2.thumbnail&.alive&.as_json,
        "display_price_cents" => membership_collab_2.display_price_cents,
        "url" => membership_collab_2.long_url,
        "url_without_protocol" => membership_collab_2.long_url(include_protocol: false),
        "has_duration" => membership_collab_2.duration_in_months.present?,
        "cut" => membership_collab_2.percentage_revenue_cut_for_user(user),
        "can_edit" => true,
        "successful_sales_count" => 1,
        "remaining_for_sale_count" => nil,
        "monthly_recurring_revenue" => membership_collab_2.monthly_recurring_revenue,
        "revenue_pending" => 0.0,
        "total_usd_cents" => 500,
      },
    ]
  end

  before do
    purchases = successful_not_reversed_purchases + [chargedback_purchase, non_collab_purchase, affiliate_purchase]
    purchases.each do |purchase|
      purchase.process!
      purchase.update_balance_and_mark_successful!
    end

    # chargeback purchase
    allow_any_instance_of(Purchase).to receive(:fight_chargeback).and_return(true)
    event_flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, chargedback_purchase.total_transaction_cents)
    event = build(:charge_event_dispute_formalized, charge_id: chargedback_purchase.stripe_transaction_id, flow_of_funds: event_flow_of_funds)
    chargedback_purchase.handle_event_dispute_formalized!(event)
    chargedback_purchase.reload

    # failed purchase
    failed_purchase.mark_failed!
  end

  describe "#initial_page_props", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    it "returns stats and collab products" do
      props = described_class.new(pundit_user:).initial_page_props

      stats = {
        total_revenue:,
        total_customers: 4,
        total_members: 3,
        total_collaborations: 5,
      }

      expect(props.keys).to match_array [:stats, :archived_tab_visible, :products, :products_pagination, :memberships, :memberships_pagination, :collaborators_disabled_reason]
      expect(props[:stats]).to match stats
      expect(props[:products_pagination]).to match({ page: 1, pages: 1 })
      expect(props[:memberships_pagination]).to match({ page: 1, pages: 1 })
      expect(props[:products]).to match_array products_props
      expect(props[:memberships]).to match_array memberships_props
      expect(props[:collaborators_disabled_reason]).to be nil
    end

    it "returns collaborators_disabled_reason if using Brazilian Stripe Connect account" do
      brazilian_stripe_account = create(:merchant_account_stripe_connect, user: pundit_user.seller, country: "BR")
      pundit_user.seller.update!(check_merchant_account_is_linked: true)
      expect(pundit_user.seller.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

      props = described_class.new(pundit_user:).initial_page_props
      expect(props[:collaborators_disabled_reason]).to eq "Collaborators with Brazilian Stripe accounts are not supported."
    end

    it "caches product data", :sidekiq_inline do
      expect do
        described_class.new(pundit_user:).initial_page_props
      end.to change { ProductCachedValue.count }.from(0).to(5)
    end
  end

  describe "#products_table_props", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    it "returns product details" do
      props = described_class.new(pundit_user:).products_table_props

      expect(props.keys).to match_array [:products, :products_pagination]
      expect(props[:products]).to match_array products_props
    end

    it "caches product data", :sidekiq_inline do
      expect do
        described_class.new(pundit_user:).products_table_props
      end.to change { ProductCachedValue.count }.from(0).to(3)
    end
  end

  describe "#memberships_table_props", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    it "returns memberships details" do
      props = described_class.new(pundit_user:).memberships_table_props

      expect(props.keys).to match_array [:memberships, :memberships_pagination]
      expect(props[:memberships]).to match_array memberships_props
    end

    it "caches memberships data", :sidekiq_inline do
      expect do
        described_class.new(pundit_user:).memberships_table_props
      end.to change { ProductCachedValue.count }.from(0).to(2)
    end
  end
end
