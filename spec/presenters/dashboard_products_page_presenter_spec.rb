# frozen_string_literal: true

require "spec_helper"
require "shared_examples/with_sorting_and_pagination"

describe DashboardProductsPagePresenter do
  let(:marketing_for_seller) { create(:user, username: "marketingforseller") }
  let(:support_for_seller) { create(:user, username: "supportforseller") }
  let(:seller) { create(:named_seller) }
  let(:pundit_user) { SellerContext.new(user: marketing_for_seller, seller:) }

  before do
    create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  describe "#page_props" do
    let!(:archived_product) { create(:product, user: seller, archived: true) }

    it "returns archived_products_count and can_create_product" do
      presenter = described_class.new(pundit_user:)

      expect(presenter.page_props).to eq({
                                           archived_products_count: 1,
                                           can_create_product: true
                                         })
    end
  end

  describe "#products_table_props" do
    include Rails.application.routes.url_helpers

    let!(:product) { create(:product, user: seller, name: "normal_product", price_cents: 1000) }
    let!(:archived_product) { create(:product, user: seller, name: "archived_product", archived: true) }
    let!(:deleted_product) { create(:product, user: seller, name: "deleted_product", deleted_at: Time.current) }
    let!(:other_user_product) { create(:product, name: "other_product") }

    it "returns only the seller's visible non-archived products" do
      presenter = described_class.new(pundit_user:)
      product_names = presenter.products_table_props[:products].map { |p| p["name"] }

      expect(product_names).to include("normal_product")
      expect(product_names).not_to include("archived_product")
      expect(product_names).not_to include("deleted_product")
      expect(product_names).not_to include("other_product")
    end

    it "returns products with correct properties" do
      presenter = described_class.new(pundit_user:)
      returned_product = presenter.products_table_props[:products].first

      expect(returned_product).to include(
        "id" => product.id,
        "name" => "normal_product",
        "edit_url" => edit_link_path(product),
        "is_duplicating" => false,
        "is_unpublished" => false,
        "permalink" => product.unique_permalink,
        "price_formatted" => product.price_formatted_including_rental_verbose,
        "revenue" => product.total_usd_cents,
        "status" => "published",
        "thumbnail" => product.thumbnail&.alive&.as_json,
        "display_price_cents" => product.display_price_cents,
        "url" => product.long_url,
        "url_without_protocol" => product.long_url(include_protocol: false),
        "has_duration" => false,
        "successful_sales_count" => product.successful_sales_count,
        "remaining_for_sale_count" => product.remaining_for_sale_count,
        "monthly_recurring_revenue" => product.monthly_recurring_revenue.to_f,
        "revenue_pending" => product.revenue_pending.to_f,
        "can_edit" => true,
        "can_destroy" => true,
        "can_duplicate" => true,
        "can_archive" => true,
        "can_unarchive" => false
      )
    end

    context "with search query" do
      let!(:another_product) { create(:product, user: seller, name: "another_product") }

      it "filters products by name" do
        presenter = described_class.new(pundit_user:, query: "another")
        product_names = presenter.products_table_props[:products].map { |p| p["name"] }

        expect(product_names).to include("another_product")
        expect(product_names).not_to include("normal_product")
      end

      it "returns empty results for a query that matches no products" do
        presenter = described_class.new(pundit_user:, query: "nonexistent_xyz")
        expect(presenter.products_table_props[:products]).to be_empty
      end
    end

    context "when the user has read-only access" do
      let(:pundit_user) { SellerContext.new(user: support_for_seller, seller:) }

      it "returns correct policy props" do
        presenter = described_class.new(pundit_user:)
        returned_product = presenter.products_table_props[:products].first

        expect(returned_product).to include(
          "can_edit" => false,
          "can_destroy" => false,
          "can_duplicate" => false,
          "can_archive" => false,
          "can_unarchive" => false
        )
      end
    end
  end

  describe "#memberships_table_props" do
    include Rails.application.routes.url_helpers

    let!(:membership) { create(:membership_product, user: seller, name: "normal_membership") }
    let!(:archived_membership) { create(:membership_product, user: seller, name: "archived_membership", archived: true) }
    let!(:deleted_membership) { create(:membership_product, user: seller, name: "deleted_membership", deleted_at: Time.current) }
    let!(:other_user_membership) { create(:membership_product, name: "other_membership") }

    it "returns only the seller's visible non-archived memberships" do
      presenter = described_class.new(pundit_user:)
      membership_names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

      expect(membership_names).to include("normal_membership")
      expect(membership_names).not_to include("archived_membership")
      expect(membership_names).not_to include("deleted_membership")
      expect(membership_names).not_to include("other_membership")
    end

    it "returns memberships with correct properties" do
      presenter = described_class.new(pundit_user:)
      returned_membership = presenter.memberships_table_props[:memberships].first

      expect(returned_membership).to include(
        "id" => membership.id,
        "name" => "normal_membership",
        "edit_url" => edit_link_path(membership),
        "is_duplicating" => false,
        "is_unpublished" => false,
        "permalink" => membership.unique_permalink,
        "price_formatted" => membership.price_formatted_including_rental_verbose,
        "revenue" => membership.total_usd_cents,
        "status" => "published",
        "thumbnail" => membership.thumbnail&.alive&.as_json,
        "display_price_cents" => membership.display_price_cents,
        "url" => membership.long_url,
        "url_without_protocol" => membership.long_url(include_protocol: false),
        "has_duration" => membership.duration_in_months.present?,
        "successful_sales_count" => membership.successful_sales_count,
        "remaining_for_sale_count" => membership.remaining_for_sale_count,
        "monthly_recurring_revenue" => membership.monthly_recurring_revenue.to_f,
        "revenue_pending" => membership.revenue_pending.to_f,
        "can_edit" => true,
        "can_destroy" => true,
        "can_duplicate" => true,
        "can_archive" => true,
        "can_unarchive" => false
      )
    end

    context "with search query" do
      let!(:another_membership) { create(:membership_product, user: seller, name: "another_membership") }

      it "filters memberships by name" do
        presenter = described_class.new(pundit_user:, query: "another")
        membership_names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

        expect(membership_names).to include("another_membership")
        expect(membership_names).not_to include("normal_membership")
      end

      it "returns empty results for a query that matches no memberships" do
        presenter = described_class.new(pundit_user:, query: "nonexistent_xyz")
        expect(presenter.memberships_table_props[:memberships]).to be_empty
      end
    end

    context "when the user has read-only access" do
      let(:pundit_user) { SellerContext.new(user: support_for_seller, seller:) }

      it "returns correct policy props" do
        presenter = described_class.new(pundit_user:)
        returned_membership = presenter.memberships_table_props[:memberships].first

        expect(returned_membership).to include(
          "can_edit" => false,
          "can_destroy" => false,
          "can_duplicate" => false,
          "can_archive" => false,
          "can_unarchive" => false
        )
      end
    end
  end

  describe "products pagination" do
    let!(:products) { create_list(:product, 5, user: seller) }

    before do
      stub_const("DashboardProductsPagePresenter::PER_PAGE", 2)
    end

    it "returns paginated products" do
      props = described_class.new(pundit_user:, products_page: 1).products_table_props

      expect(props[:products].length).to eq(2)
      expect(props[:products_pagination]).to eq(page: 1, pages: 3)
    end

    it "returns correct page of products" do
      page1_props = described_class.new(pundit_user:, products_page: 1).products_table_props
      page2_props = described_class.new(pundit_user:, products_page: 2).products_table_props

      expect(page1_props[:products_pagination]).to eq(page: 1, pages: 3)
      expect(page2_props[:products_pagination]).to eq(page: 2, pages: 3)

      page1_ids = page1_props[:products].map { |p| p["id"] }
      page2_ids = page2_props[:products].map { |p| p["id"] }
      expect(page1_ids & page2_ids).to be_empty
      expect((page1_ids + page2_ids) - products.map(&:id)).to be_empty
    end

    it "raises on page overflow" do
      expect { described_class.new(pundit_user:, products_page: 10).products_table_props }.to raise_error(Pagy::OverflowError)
    end

    context "when some products are deleted" do
      before do
        products.first(2).each { |p| p.update!(deleted_at: Time.current) }
      end

      it "paginates only visible products" do
        props = described_class.new(pundit_user:, products_page: 1).products_table_props

        expect(props[:products].length).to eq(2)
        expect(props[:products_pagination]).to eq(page: 1, pages: 2)
      end
    end
  end

  describe "memberships pagination" do
    let!(:memberships) { create_list(:membership_product, 5, user: seller) }

    before do
      stub_const("DashboardProductsPagePresenter::PER_PAGE", 2)
    end

    it "returns paginated memberships" do
      props = described_class.new(pundit_user:, memberships_page: 1).memberships_table_props

      expect(props[:memberships].length).to eq(2)
      expect(props[:memberships_pagination]).to eq(page: 1, pages: 3)
    end

    it "returns correct page of memberships" do
      page1_props = described_class.new(pundit_user:, memberships_page: 1).memberships_table_props
      page2_props = described_class.new(pundit_user:, memberships_page: 2).memberships_table_props

      expect(page1_props[:memberships_pagination]).to eq(page: 1, pages: 3)
      expect(page2_props[:memberships_pagination]).to eq(page: 2, pages: 3)

      page1_ids = page1_props[:memberships].map { |m| m["id"] }
      page2_ids = page2_props[:memberships].map { |m| m["id"] }
      expect(page1_ids & page2_ids).to be_empty
      expect((page1_ids + page2_ids) - memberships.map(&:id)).to be_empty
    end

    it "raises on page overflow" do
      expect { described_class.new(pundit_user:, memberships_page: 10).memberships_table_props }.to raise_error(Pagy::OverflowError)
    end

    context "when some memberships are deleted" do
      before do
        memberships.first(2).each { |m| m.update!(deleted_at: Time.current) }
      end

      it "paginates only visible memberships" do
        props = described_class.new(pundit_user:, memberships_page: 1).memberships_table_props

        expect(props[:memberships].length).to eq(2)
        expect(props[:memberships_pagination]).to eq(page: 1, pages: 2)
      end
    end
  end

  describe "sorting + pagination", :elasticsearch_wait_for_refresh do
    include_context "with products and memberships"

    before do
      stub_const("DashboardProductsPagePresenter::PER_PAGE", 2)
    end

    describe "products" do
      it "sorts by name ascending" do
        presenter = described_class.new(pundit_user:, products_sort: { key: "name", direction: "asc" })
        names = presenter.products_table_props[:products].map { |p| p["name"] }

        expect(names).to eq(["Product 1", "Product 2"])
      end

      it "sorts by name descending" do
        presenter = described_class.new(pundit_user:, products_sort: { key: "name", direction: "desc" })
        names = presenter.products_table_props[:products].map { |p| p["name"] }

        expect(names).to eq(["Product 4", "Product 3"])
      end

      it "paginates sorted results correctly" do
        page1 = described_class.new(pundit_user:, products_sort: { key: "name", direction: "asc" }, products_page: 1).products_table_props
        page2 = described_class.new(pundit_user:, products_sort: { key: "name", direction: "asc" }, products_page: 2).products_table_props

        expect(page1[:products].map { |p| p["name"] }).to eq(["Product 1", "Product 2"])
        expect(page2[:products].map { |p| p["name"] }).to eq(["Product 3", "Product 4"])
        expect(page1[:products_pagination]).to eq(page: 1, pages: 2)
        expect(page2[:products_pagination]).to eq(page: 2, pages: 2)
      end

      it "sorts by successful_sales_count ascending" do
        presenter = described_class.new(pundit_user:, products_sort: { key: "successful_sales_count", direction: "asc" })
        names = presenter.products_table_props[:products].map { |p| p["name"] }

        expect(names).to eq(["Product 1", "Product 2"])
      end

      it "sorts by successful_sales_count descending" do
        presenter = described_class.new(pundit_user:, products_sort: { key: "successful_sales_count", direction: "desc" })
        names = presenter.products_table_props[:products].map { |p| p["name"] }

        expect(names).to eq(["Product 4", "Product 3"])
      end

      it "sorts by revenue ascending" do
        presenter = described_class.new(pundit_user:, products_sort: { key: "revenue", direction: "asc" })
        names = presenter.products_table_props[:products].map { |p| p["name"] }

        expect(names).to eq(["Product 3", "Product 2"])
      end

      it "sorts by revenue descending" do
        presenter = described_class.new(pundit_user:, products_sort: { key: "revenue", direction: "desc" })
        names = presenter.products_table_props[:products].map { |p| p["name"] }

        expect(names).to eq(["Product 4", "Product 1"])
      end

      it "sorts by display_price_cents ascending" do
        presenter = described_class.new(pundit_user:, products_sort: { key: "display_price_cents", direction: "asc" })
        names = presenter.products_table_props[:products].map { |p| p["name"] }

        expect(names).to eq(["Product 3", "Product 4"])
      end

      it "sorts by display_price_cents descending" do
        presenter = described_class.new(pundit_user:, products_sort: { key: "display_price_cents", direction: "desc" })
        names = presenter.products_table_props[:products].map { |p| p["name"] }

        expect(names).to eq(["Product 1", "Product 2"])
      end

      it "sorts by status ascending (unpublished first)" do
        presenter = described_class.new(pundit_user:, products_sort: { key: "status", direction: "asc" })
        names = presenter.products_table_props[:products].map { |p| p["name"] }

        expect(names).to match_array(["Product 3", "Product 4"])
      end

      it "sorts by status descending (published first)" do
        presenter = described_class.new(pundit_user:, products_sort: { key: "status", direction: "desc" })
        names = presenter.products_table_props[:products].map { |p| p["name"] }

        expect(names).to match_array(["Product 1", "Product 2"])
      end
    end

    describe "memberships" do
      it "sorts by name ascending" do
        presenter = described_class.new(pundit_user:, memberships_sort: { key: "name", direction: "asc" })
        names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

        expect(names).to eq(["Membership 1", "Membership 2"])
      end

      it "sorts by name descending" do
        presenter = described_class.new(pundit_user:, memberships_sort: { key: "name", direction: "desc" })
        names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

        expect(names).to eq(["Membership 4", "Membership 3"])
      end

      it "paginates sorted results correctly" do
        page1 = described_class.new(pundit_user:, memberships_sort: { key: "name", direction: "asc" }, memberships_page: 1).memberships_table_props
        page2 = described_class.new(pundit_user:, memberships_sort: { key: "name", direction: "asc" }, memberships_page: 2).memberships_table_props

        expect(page1[:memberships].map { |m| m["name"] }).to eq(["Membership 1", "Membership 2"])
        expect(page2[:memberships].map { |m| m["name"] }).to eq(["Membership 3", "Membership 4"])
        expect(page1[:memberships_pagination]).to eq(page: 1, pages: 2)
        expect(page2[:memberships_pagination]).to eq(page: 2, pages: 2)
      end

      it "sorts by successful_sales_count ascending" do
        presenter = described_class.new(pundit_user:, memberships_sort: { key: "successful_sales_count", direction: "asc" })
        names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

        expect(names).to eq(["Membership 4", "Membership 1"])
      end

      it "sorts by successful_sales_count descending" do
        presenter = described_class.new(pundit_user:, memberships_sort: { key: "successful_sales_count", direction: "desc" })
        names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

        expect(names).to eq(["Membership 2", "Membership 3"])
      end

      it "sorts by revenue ascending" do
        presenter = described_class.new(pundit_user:, memberships_sort: { key: "revenue", direction: "asc" })
        names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

        expect(names).to eq(["Membership 4", "Membership 1"])
      end

      it "sorts by revenue descending" do
        presenter = described_class.new(pundit_user:, memberships_sort: { key: "revenue", direction: "desc" })
        names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

        expect(names).to eq(["Membership 2", "Membership 3"])
      end

      it "sorts by display_price_cents ascending" do
        presenter = described_class.new(pundit_user:, memberships_sort: { key: "display_price_cents", direction: "asc" })
        names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

        expect(names).to eq(["Membership 4", "Membership 3"])
      end

      it "sorts by display_price_cents descending" do
        presenter = described_class.new(pundit_user:, memberships_sort: { key: "display_price_cents", direction: "desc" })
        names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

        expect(names).to eq(["Membership 1", "Membership 2"])
      end

      it "sorts by status ascending (unpublished first)" do
        presenter = described_class.new(pundit_user:, memberships_sort: { key: "status", direction: "asc" })
        names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

        expect(names).to match_array(["Membership 3", "Membership 4"])
      end

      it "sorts by status descending (published first)" do
        presenter = described_class.new(pundit_user:, memberships_sort: { key: "status", direction: "desc" })
        names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

        expect(names).to match_array(["Membership 1", "Membership 2"])
      end
    end
  end

  describe "caching", :sidekiq_inline do
    let!(:product) { create(:product, user: seller) }
    let!(:membership) { create(:membership_product, user: seller) }

    it "caches dashboard data" do
      presenter = described_class.new(pundit_user:)

      expect do
        presenter.products_table_props
        presenter.memberships_table_props
      end.to change { ProductCachedValue.count }.by(2)
    end
  end

  context "with archived: true" do
    describe "#empty?" do
      context "when there are no archived products or memberships" do
        before do
          create(:product, user: seller)
          create(:membership_product, user: seller)
        end

        it "returns true" do
          presenter = described_class.new(pundit_user:, archived: true)
          expect(presenter.empty?).to be(true)
        end
      end

      context "when there are archived products" do
        before do
          create(:product, user: seller, archived: true)
        end

        it "returns false" do
          presenter = described_class.new(pundit_user:, archived: true)
          expect(presenter.empty?).to be(false)
        end
      end

      context "when there are archived memberships" do
        before do
          create(:membership_product, user: seller, archived: true)
        end

        it "returns false" do
          presenter = described_class.new(pundit_user:, archived: true)
          expect(presenter.empty?).to be(false)
        end
      end

      context "when there are only deleted archived products" do
        before do
          create(:product, user: seller, archived: true, deleted_at: Time.current)
        end

        it "returns true" do
          presenter = described_class.new(pundit_user:, archived: true)
          expect(presenter.empty?).to be(true)
        end
      end
    end

    describe "#page_props" do
      it "returns only can_create_product (no archived_products_count)" do
        presenter = described_class.new(pundit_user:, archived: true)
        expect(presenter.page_props).to eq({ can_create_product: true })
      end
    end

    describe "#products_table_props" do
      include Rails.application.routes.url_helpers

      let!(:archived_product) { create(:product, user: seller, name: "archived_product", archived: true, price_cents: 1500) }
      let!(:normal_product) { create(:product, user: seller, name: "normal_product") }
      let!(:deleted_archived_product) { create(:product, user: seller, name: "deleted_archived", archived: true, deleted_at: Time.current) }
      let!(:other_user_archived_product) { create(:product, name: "other_archived", archived: true) }

      it "returns only the seller's archived products" do
        presenter = described_class.new(pundit_user:, archived: true)
        product_names = presenter.products_table_props[:products].map { |p| p["name"] }

        expect(product_names).to include("archived_product")
        expect(product_names).not_to include("normal_product")
        expect(product_names).not_to include("deleted_archived")
        expect(product_names).not_to include("other_archived")
      end

      it "returns products with correct properties" do
        presenter = described_class.new(pundit_user:, archived: true)
        returned_product = presenter.products_table_props[:products].first

        expect(returned_product).to include(
          "id" => archived_product.id,
          "name" => "archived_product",
          "edit_url" => edit_link_path(archived_product),
          "is_duplicating" => archived_product.is_duplicating?,
          "is_unpublished" => archived_product.draft? || archived_product.purchase_disabled_at?,
          "permalink" => archived_product.unique_permalink,
          "price_formatted" => archived_product.price_formatted_including_rental_verbose,
          "revenue" => archived_product.total_usd_cents,
          "thumbnail" => archived_product.thumbnail&.alive&.as_json,
          "display_price_cents" => archived_product.display_price_cents,
          "url" => archived_product.long_url,
          "url_without_protocol" => archived_product.long_url(include_protocol: false),
          "has_duration" => archived_product.duration_in_months.present?,
          "successful_sales_count" => archived_product.successful_sales_count,
          "remaining_for_sale_count" => archived_product.remaining_for_sale_count,
          "monthly_recurring_revenue" => archived_product.monthly_recurring_revenue.to_f,
          "revenue_pending" => archived_product.revenue_pending.to_f,
          "can_edit" => true,
          "can_destroy" => true,
          "can_duplicate" => true,
          "can_archive" => false,
          "can_unarchive" => true
        )
      end

      context "with search query" do
        let!(:another_archived) { create(:product, user: seller, name: "another_archived", archived: true) }

        it "filters products by name" do
          presenter = described_class.new(pundit_user:, archived: true, query: "another")
          product_names = presenter.products_table_props[:products].map { |p| p["name"] }

          expect(product_names).to include("another_archived")
          expect(product_names).not_to include("archived_product")
        end

        it "returns empty results for a query that matches no archived products" do
          presenter = described_class.new(pundit_user:, archived: true, query: "nonexistent_xyz")
          expect(presenter.products_table_props[:products]).to be_empty
        end
      end
    end

    describe "#memberships_table_props" do
      include Rails.application.routes.url_helpers

      let!(:archived_membership) { create(:membership_product, user: seller, name: "archived_membership", archived: true) }
      let!(:normal_membership) { create(:membership_product, user: seller, name: "normal_membership") }
      let!(:deleted_archived_membership) { create(:membership_product, user: seller, name: "deleted_archived", archived: true, deleted_at: Time.current) }
      let!(:other_user_archived_membership) { create(:membership_product, name: "other_archived", archived: true) }

      it "returns only the seller's archived memberships" do
        presenter = described_class.new(pundit_user:, archived: true)
        membership_names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

        expect(membership_names).to include("archived_membership")
        expect(membership_names).not_to include("normal_membership")
        expect(membership_names).not_to include("deleted_archived")
        expect(membership_names).not_to include("other_archived")
      end

      it "returns memberships with correct properties" do
        presenter = described_class.new(pundit_user:, archived: true)
        returned_membership = presenter.memberships_table_props[:memberships].first

        expect(returned_membership).to include(
          "id" => archived_membership.id,
          "name" => "archived_membership",
          "edit_url" => edit_link_path(archived_membership),
          "is_duplicating" => archived_membership.is_duplicating?,
          "is_unpublished" => archived_membership.draft? || archived_membership.purchase_disabled_at?,
          "permalink" => archived_membership.unique_permalink,
          "price_formatted" => archived_membership.price_formatted_including_rental_verbose,
          "revenue" => archived_membership.total_usd_cents,
          "thumbnail" => archived_membership.thumbnail&.alive&.as_json,
          "display_price_cents" => archived_membership.display_price_cents,
          "url" => archived_membership.long_url,
          "url_without_protocol" => archived_membership.long_url(include_protocol: false),
          "has_duration" => archived_membership.duration_in_months.present?,
          "successful_sales_count" => archived_membership.successful_sales_count,
          "remaining_for_sale_count" => archived_membership.remaining_for_sale_count,
          "monthly_recurring_revenue" => archived_membership.monthly_recurring_revenue.to_f,
          "revenue_pending" => archived_membership.revenue_pending.to_f,
          "can_edit" => true,
          "can_destroy" => true,
          "can_duplicate" => true,
          "can_archive" => false,
          "can_unarchive" => true
        )
      end

      context "with search query" do
        let!(:another_archived) { create(:membership_product, user: seller, name: "another_archived", archived: true) }

        it "filters memberships by name" do
          presenter = described_class.new(pundit_user:, archived: true, query: "another")
          membership_names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

          expect(membership_names).to include("another_archived")
          expect(membership_names).not_to include("archived_membership")
        end

        it "returns empty results for a query that matches no archived memberships" do
          presenter = described_class.new(pundit_user:, archived: true, query: "nonexistent_xyz")
          expect(presenter.memberships_table_props[:memberships]).to be_empty
        end
      end
    end

    describe "products pagination" do
      let!(:archived_products) { create_list(:product, 5, user: seller, archived: true) }

      before do
        stub_const("DashboardProductsPagePresenter::PER_PAGE", 2)
      end

      it "returns paginated products" do
        props = described_class.new(pundit_user:, archived: true, products_page: 1).products_table_props

        expect(props[:products].length).to eq(2)
        expect(props[:products_pagination]).to eq(page: 1, pages: 3)
      end

      it "returns correct page of products" do
        page1_props = described_class.new(pundit_user:, archived: true, products_page: 1).products_table_props
        page2_props = described_class.new(pundit_user:, archived: true, products_page: 2).products_table_props

        expect(page1_props[:products_pagination]).to eq(page: 1, pages: 3)
        expect(page2_props[:products_pagination]).to eq(page: 2, pages: 3)

        page1_ids = page1_props[:products].map { |p| p["id"] }
        page2_ids = page2_props[:products].map { |p| p["id"] }
        expect(page1_ids & page2_ids).to be_empty
        expect((page1_ids + page2_ids) - archived_products.map(&:id)).to be_empty
      end
    end

    describe "memberships pagination" do
      let!(:archived_memberships) { create_list(:membership_product, 5, user: seller, archived: true) }

      before do
        stub_const("DashboardProductsPagePresenter::PER_PAGE", 2)
      end

      it "returns paginated memberships" do
        props = described_class.new(pundit_user:, archived: true, memberships_page: 1).memberships_table_props

        expect(props[:memberships].length).to eq(2)
        expect(props[:memberships_pagination]).to eq(page: 1, pages: 3)
      end

      it "returns correct page of memberships" do
        page1_props = described_class.new(pundit_user:, archived: true, memberships_page: 1).memberships_table_props
        page2_props = described_class.new(pundit_user:, archived: true, memberships_page: 2).memberships_table_props

        expect(page1_props[:memberships_pagination]).to eq(page: 1, pages: 3)
        expect(page2_props[:memberships_pagination]).to eq(page: 2, pages: 3)

        page1_ids = page1_props[:memberships].map { |m| m["id"] }
        page2_ids = page2_props[:memberships].map { |m| m["id"] }
        expect(page1_ids & page2_ids).to be_empty
        expect((page1_ids + page2_ids) - archived_memberships.map(&:id)).to be_empty
      end
    end

    describe "sorting", :elasticsearch_wait_for_refresh do
      include_context "with products and memberships", archived: true

      describe "archived products" do
        it "sorts by name ascending" do
          presenter = described_class.new(pundit_user:, archived: true, products_sort: { key: "name", direction: "asc" })
          names = presenter.products_table_props[:products].map { |p| p["name"] }

          expect(names).to eq(["Product 1", "Product 2", "Product 3", "Product 4"])
        end

        it "sorts by name descending" do
          presenter = described_class.new(pundit_user:, archived: true, products_sort: { key: "name", direction: "desc" })
          names = presenter.products_table_props[:products].map { |p| p["name"] }

          expect(names).to eq(["Product 4", "Product 3", "Product 2", "Product 1"])
        end

        it "sorts by successful_sales_count ascending" do
          presenter = described_class.new(pundit_user:, archived: true, products_sort: { key: "successful_sales_count", direction: "asc" })
          names = presenter.products_table_props[:products].map { |p| p["name"] }

          expect(names).to eq(["Product 1", "Product 2", "Product 3", "Product 4"])
        end

        it "sorts by revenue descending" do
          presenter = described_class.new(pundit_user:, archived: true, products_sort: { key: "revenue", direction: "desc" })
          names = presenter.products_table_props[:products].map { |p| p["name"] }

          expect(names).to eq(["Product 4", "Product 1", "Product 2", "Product 3"])
        end

        it "sorts by display_price_cents ascending" do
          presenter = described_class.new(pundit_user:, archived: true, products_sort: { key: "display_price_cents", direction: "asc" })
          names = presenter.products_table_props[:products].map { |p| p["name"] }

          expect(names).to eq(["Product 3", "Product 4", "Product 2", "Product 1"])
        end
      end

      describe "archived memberships" do
        it "sorts by name ascending" do
          presenter = described_class.new(pundit_user:, archived: true, memberships_sort: { key: "name", direction: "asc" })
          names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

          expect(names).to eq(["Membership 1", "Membership 2", "Membership 3", "Membership 4"])
        end

        it "sorts by name descending" do
          presenter = described_class.new(pundit_user:, archived: true, memberships_sort: { key: "name", direction: "desc" })
          names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

          expect(names).to eq(["Membership 4", "Membership 3", "Membership 2", "Membership 1"])
        end

        it "sorts by successful_sales_count descending" do
          presenter = described_class.new(pundit_user:, archived: true, memberships_sort: { key: "successful_sales_count", direction: "desc" })
          names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

          expect(names).to eq(["Membership 2", "Membership 3", "Membership 1", "Membership 4"])
        end

        it "sorts by revenue ascending" do
          presenter = described_class.new(pundit_user:, archived: true, memberships_sort: { key: "revenue", direction: "asc" })
          names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

          expect(names).to eq(["Membership 4", "Membership 1", "Membership 3", "Membership 2"])
        end

        it "sorts by display_price_cents descending" do
          presenter = described_class.new(pundit_user:, archived: true, memberships_sort: { key: "display_price_cents", direction: "desc" })
          names = presenter.memberships_table_props[:memberships].map { |m| m["name"] }

          expect(names).to eq(["Membership 1", "Membership 2", "Membership 3", "Membership 4"])
        end
      end
    end
  end

  describe "#empty?" do
    context "when archived: false (default)" do
      it "returns nil" do
        presenter = described_class.new(pundit_user:)
        expect(presenter.empty?).to be_nil
      end
    end
  end
end
