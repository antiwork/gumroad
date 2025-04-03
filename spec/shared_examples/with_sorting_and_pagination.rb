# frozen_string_literal: true

require "spec_helper"

def product_names(response)
  response.parsed_body["entries"].map { _1["name"] }
end

RSpec.shared_examples_for "an API for sorting and pagination" do |action|
  it "correctly sorts and paginates the records" do
    if default_order.present?
      order = default_order.map(&:name)

      get action, params: { page: 1, sort: nil }
      expect(product_names(response)).to eq(order.first(2))

      get action, params: { page: 2, sort: nil }
      expect(product_names(response)).to eq(order.last(2))
    end

    # For columns that reverse the order of all records when toggling direction
    columns.each do |key, order|
      order = order.map(&:name)

      get action, params: { page: 1, sort: { key:, direction: "asc" } }
      expect(product_names(response)).to eq(order.first(2))

      get action, params: { page: 1, sort: { key:, direction: "desc" } }
      expect(product_names(response)).to eq(order.reverse.first(2))

      get action, params: { page: 2, sort: { key:, direction: "asc" } }
      expect(product_names(response)).to eq(order.last(2))

      get action, params: { page: 2, sort: { key:, direction: "desc" } }
      expect(product_names(response)).to eq(order.reverse.last(2))
    end

    # For columns that group records into two categories and reorders those categories when toggling direction
    boolean_columns.each do |key, order|
      order = order.map(&:name)

      get action, params: { page: 1, sort: { key:, direction: "asc" } }
      expect(product_names(response)).to eq(order.first(2))

      get action, params: { page: 1, sort: { key:, direction: "desc" } }
      expect(product_names(response)).to eq(order.last(2))

      get action, params: { page: 2, sort: { key:, direction: "asc" } }
      expect(product_names(response)).to eq(order.last(2))

      get action, params: { page: 2, sort: { key:, direction: "desc" } }
      expect(product_names(response)).to eq(order.first(2))
    end
  end
end

RSpec.shared_examples_for "a table with sorting" do |table_name|
  it "correctly sorts the records" do
    table = find(:table, table_name)

    if default_order.present?
      order = default_order.map(&:name)

      within table do
        expect(page).to have_nth_table_row_record(1, order.first, exact_text: false)
        expect(page).to have_nth_table_row_record(2, order.second, exact_text: false)
      end
    end

    # For columns that reverse the order of all records when toggling direction
    columns.each do |column, order|
      order = order.map(&:name)

      within table do
        find(:columnheader, column).click
        wait_for_ajax
      end

      expect(page).to have_nth_table_row_record(1, order.first, exact_text: false)
      expect(page).to have_nth_table_row_record(2, order.second, exact_text: false)

      within table do
        find(:columnheader, column).click
        wait_for_ajax
      end

      expect(page).to have_nth_table_row_record(1, order.reverse.first, exact_text: false)
      expect(page).to have_nth_table_row_record(2, order.reverse.second, exact_text: false)
    end

    # For columns that group records into two categories and reorders those categories when toggling direction
    boolean_columns.each do |column, order|
      order = order.map(&:name)

      within table do
        find(:columnheader, column).click
        wait_for_ajax
      end

      expect(page).to have_nth_table_row_record(1, order.first, exact_text: false)
      expect(page).to have_nth_table_row_record(2, order.second, exact_text: false)

      within table do
        find(:columnheader, column).click
        wait_for_ajax
      end

      expect(page).to have_nth_table_row_record(1, order.third, exact_text: false)
      expect(page).to have_nth_table_row_record(2, order.fourth, exact_text: false)
    end
  end
end

RSpec.shared_context "with products and memberships" do |archived: false|
  let!(:membership1) { create(:subscription_product, name: "Membership 1", archived:, user: seller, price_cents: 1000, created_at: 4.days.ago) }
  let!(:membership2) { create(:subscription_product, name: "Membership 2", archived:, user: seller, price_cents: 900, created_at: Time.current) }
  let!(:membership3) { create(:membership_product_with_preset_tiered_pwyw_pricing, name: "Membership 3", archived:, user: seller, purchase_disabled_at: 2.days.ago, created_at: 2.days.ago) }
  let!(:membership4) { create(:membership_product_with_preset_tiered_pricing, name: "Membership 4", archived:, user: seller, purchase_disabled_at: Time.current, created_at: 3.days.ago) }

  let!(:product1) { create(:product, name: "Product 1", archived:, user: seller, price_cents: 1000, created_at: Time.current) }
  let!(:product2) { create(:product, name: "Product 2", archived:, user: seller, price_cents: 500, created_at: 4.days.ago) }
  let!(:product3) { create(:product, name: "Product 3", archived:, user: seller, price_cents: 300, purchase_disabled_at: 2.days.ago, created_at: 2.days.ago) }
  let!(:product4) { create(:product, name: "Product 4", archived:, user: seller, price_cents: 400, purchase_disabled_at: Time.current, created_at: 3.days.ago) }

  before do
    membership3.tier_category.variants.each do |tier|
      recurrence_values = BasePrice::Recurrence.all.index_with do |recurrence_key|
        {
          enabled: true,
          price: "8",
          suggested_price: "8.5"
        }
      end
      tier.save_recurring_prices!(recurrence_values)
    end

    create(:purchase, link: membership1, is_original_subscription_purchase: true, subscription: create(:subscription, link: membership1, cancelled_at: nil), created_at: 2.days.ago)
    2.times { create(:membership_purchase, is_original_subscription_purchase: true, link: membership3, seller:, subscription: create(:subscription, link: membership3, cancelled_at: nil), price_cents: 800) }
    4.times { create(:purchase, link: membership2, is_original_subscription_purchase: true, subscription: create(:subscription, link: membership2, cancelled_at: nil), created_at: 2.days.ago) }

    create_list(:purchase, 2, link: product1)
    create_list(:purchase, 3, link: product2)
    create_list(:purchase, 4, link: product3)
    create_list(:purchase, 6, link: product4)

    index_model_records(Purchase)
    index_model_records(Link)
    membership1.product_cached_values.create!
    membership2.product_cached_values.create!
    membership3.product_cached_values.create!
    membership4.product_cached_values.create!
    product1.product_cached_values.create!
    product2.product_cached_values.create!
    product3.product_cached_values.create!
    product4.product_cached_values.create!
  end
end
