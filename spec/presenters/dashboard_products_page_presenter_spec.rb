# frozen_string_literal: true

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
    let(:membership) { create(:membership_product, user: seller, name: "Strong, stronger & <strong>strongest</strong>") }
    let(:product) { create(:product, user: seller, name: "Strong, stronger & <strong>strongest</strong>") }
    let(:presenter) do
      described_class.new(
        pundit_user:,
        memberships: [membership],
        memberships_pagination: nil,
        products: [product],
        products_pagination: nil
      )
    end

    it "caches dashboard data", :sidekiq_inline do
      expect do
        presenter.page_props
      end.to change { ProductCachedValue.count }.from(0).to(2)
    end

    context "when the user has full access" do
      it "returns memberships and products data for the dashboard products page" do
        expect(presenter.page_props).to match(
          {
            memberships: [
              {
                "id" => be_present,
                "edit_url" => be_present,
                "is_duplicating" => false,
                "is_unpublished" => false,
                "name" => "Strong, stronger & <strong>strongest</strong>",
                "permalink" => be_present,
                "price_formatted" => "$1 a month",
                "display_price_cents" => 100,
                "revenue" => 0.0,
                "status" => "published",
                "thumbnail" => nil,
                "url" => be_present,
                "url_without_protocol" => be_present,
                "has_duration" => false,
                "successful_sales_count" => 0,
                "remaining_for_sale_count" => nil,
                "monthly_recurring_revenue" => 0.0,
                "revenue_pending" => 0.0,
                "total_usd_cents" => 0,
                "can_edit" => true,
                "can_destroy" => true,
                "can_duplicate" => true,
                "can_archive" => true,
                "can_unarchive" => false
              }
            ],
            memberships_pagination: nil,
            products: [
              {
                "id" => be_present,
                "edit_url" => be_present,
                "is_duplicating" => false,
                "is_unpublished" => false,
                "name" => "Strong, stronger & <strong>strongest</strong>",
                "permalink" => be_present,
                "price_formatted" => "$1",
                "display_price_cents" => 100,
                "revenue" => 0,
                "status" => "published",
                "thumbnail" => nil,
                "url" => be_present,
                "url_without_protocol" => be_present,
                "has_duration" => false,
                "successful_sales_count" => 0,
                "remaining_for_sale_count" => nil,
                "monthly_recurring_revenue" => 0.0,
                "revenue_pending" => 0.0,
                "total_usd_cents" => 0,
                "can_edit" => true,
                "can_destroy" => true,
                "can_duplicate" => true,
                "can_archive" => true,
                "can_unarchive" => false
              },
            ],
            products_pagination: nil,
            archived_products_count: 0,
            can_create_product: true,
          }
        )
      end
    end

    context "when the user has read-only access" do
      let(:expected_policy_props) do
        {
          "can_edit" => false,
          "can_destroy" => false,
          "can_duplicate" => false,
          "can_archive" => false,
          "can_unarchive" => false,
        }
      end
      let(:pundit_user) { SellerContext.new(user: support_for_seller, seller:) }

      it "returns correct policy props" do
        expect(presenter.page_props[:memberships].first.slice(*expected_policy_props.keys)).to eq(expected_policy_props)
        expect(presenter.page_props[:products].first.slice(*expected_policy_props.keys)).to eq(expected_policy_props)
      end
    end
  end

  describe "#memberships_table_props" do
    before do
      @memberships = create_list(:membership_product, 2, user: seller)
      @instance = described_class.new(
        pundit_user:,
        memberships: @memberships,
        memberships_pagination: nil,
        products: nil,
        products_pagination: nil
      )
    end

    it "returns memberships data for the memberships table component" do
      expect(@instance.memberships_table_props).to match(
        {
          memberships: [
            {
              "id" => be_present,
              "edit_url" => be_present,
              "is_duplicating" => false,
              "is_unpublished" => false,
              "name" => "The Works of Edgar Gumstein",
              "permalink" => be_present,
              "price_formatted" => "$1 a month",
              "display_price_cents" => 100,
              "revenue" => 0,
              "status" => "published",
              "thumbnail" => nil,
              "url" => be_present,
              "url_without_protocol" => be_present,
              "has_duration" => false,
              "successful_sales_count" => 0,
              "remaining_for_sale_count" => nil,
              "monthly_recurring_revenue" => 0.0,
              "revenue_pending" => 0.0,
              "total_usd_cents" => 0,
              "can_edit" => true,
              "can_destroy" => true,
              "can_duplicate" => true,
              "can_archive" => true,
              "can_unarchive" => false
            },
            {
              "id" => be_present,
              "edit_url" => be_present,
              "is_duplicating" => false,
              "is_unpublished" => false,
              "name" => "The Works of Edgar Gumstein",
              "permalink" => be_present,
              "price_formatted" => "$1 a month",
              "display_price_cents" => 100,
              "revenue" => 0,
              "status" => "published",
              "thumbnail" => nil,
              "url" => be_present,
              "url_without_protocol" => be_present,
              "has_duration" => false,
              "successful_sales_count" => 0,
              "remaining_for_sale_count" => nil,
              "monthly_recurring_revenue" => 0.0,
              "revenue_pending" => 0.0,
              "total_usd_cents" => 0,
              "can_edit" => true,
              "can_destroy" => true,
              "can_duplicate" => true,
              "can_archive" => true,
              "can_unarchive" => false
            }
          ],
          memberships_pagination: nil,
        }
      )
    end
  end

  describe "#products_table_props" do
    before do
      @products = create_list(:product, 2, user: seller)
      @instance = described_class.new(
        pundit_user:,
        memberships: nil,
        memberships_pagination: nil,
        products: @products,
        products_pagination: nil
      )
    end

    it "returns products data for the products table component" do
      expect(@instance.products_table_props).to match(
        {
          products: [
            {
              "id" => be_present,
              "edit_url" => be_present,
              "is_duplicating" => false,
              "is_unpublished" => false,
              "name" => "The Works of Edgar Gumstein",
              "permalink" => be_present,
              "price_formatted" => "$1",
              "display_price_cents" => 100,
              "revenue" => 0,
              "status" => "published",
              "thumbnail" => nil,
              "url" => be_present,
              "url_without_protocol" => be_present,
              "has_duration" => false,
              "successful_sales_count" => 0,
              "remaining_for_sale_count" => nil,
              "monthly_recurring_revenue" => 0.0,
              "revenue_pending" => 0.0,
              "total_usd_cents" => 0,
              "can_edit" => true,
              "can_destroy" => true,
              "can_duplicate" => true,
              "can_archive" => true,
              "can_unarchive" => false
            },
            {
              "id" => be_present,
              "edit_url" => be_present,
              "is_duplicating" => false,
              "is_unpublished" => false,
              "name" => "The Works of Edgar Gumstein",
              "permalink" => be_present,
              "price_formatted" => "$1",
              "display_price_cents" => 100,
              "revenue" => 0,
              "status" => "published",
              "thumbnail" => nil,
              "url" => be_present,
              "url_without_protocol" => be_present,
              "has_duration" => false,
              "successful_sales_count" => 0,
              "remaining_for_sale_count" => nil,
              "monthly_recurring_revenue" => 0.0,
              "revenue_pending" => 0.0,
              "total_usd_cents" => 0,
              "can_edit" => true,
              "can_destroy" => true,
              "can_duplicate" => true,
              "can_archive" => true,
              "can_unarchive" => false
            },
          ],
          products_pagination: nil
        }
      )
    end
  end
end
