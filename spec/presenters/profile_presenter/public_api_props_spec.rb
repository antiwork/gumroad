# frozen_string_literal: true

require "spec_helper"

describe ProfilePresenter::PublicApiProps do
  let(:seller) do
    create(
      :user,
      name: "Testy McTest",
      username: "testy",
      bio: "I make great things.",
      twitter_handle: "testy",
    )
  end
  let(:presenter) { described_class.new(seller:) }

  describe "#props" do
    subject(:props) { presenter.props }

    it "exposes the documented public identity fields" do
      expect(props[:api_version]).to eq(described_class::API_VERSION)
      expect(props[:id]).to eq(seller.external_id)
      expect(props[:username]).to eq("testy")
      expect(props[:name]).to eq("Testy McTest")
      expect(props[:bio]).to eq("I make great things.")
      expect(props[:twitter_handle]).to eq("testy")
      expect(props[:profile_url]).to eq(seller.profile_url)
      expect(props[:subdomain]).to eq(seller.subdomain)
      expect(props).to have_key(:avatar_url)
    end

    it "exposes is_verified reflecting the seller flag" do
      expect(props[:is_verified]).to be(false)
      seller.update!(verified: true)
      expect(described_class.new(seller:).props[:is_verified]).to be(true)
    end

    it "returns nil bio when the seller has none" do
      seller.update!(bio: nil)
      expect(described_class.new(seller:).props[:bio]).to be_nil
    end

    it "uses the seller custom domain for the profile_url when present" do
      expect(described_class.new(seller:, seller_custom_domain_url: "https://shop.example.com/").props[:profile_url]).to eq("https://shop.example.com/")
    end

    it "NEVER leaks private seller fields (email, balance, tokens)" do
      expect(props.keys.map(&:to_s)).not_to include(
        "email", "password", "unpaid_balance_cents", "balance",
        "user_risk_state", "tax_id", "payment_address", "encrypted_password"
      )
    end

    describe "products" do
      let!(:published) do
        create(:product, user: seller, name: "Published One", price_cents: 600, created_at: 2.days.ago)
      end
      let!(:second) do
        create(:product, user: seller, name: "Published Two", price_cents: 1500, created_at: 1.day.ago)
      end
      let!(:products_section) do
        create(:seller_profile_products_section, seller:, shown_products: [second.id, published.id], add_new_products: false)
      end

      before do
        seller.seller_profile.update!(
          json_data: {
            "tabs" => [
              { "name" => "Products", "sections" => [products_section.id] },
            ],
          },
        )
        Link.import(force: true, refresh: true)
      end

      it "lists the seller's published products with public fields" do
        names = props[:products].map { _1[:name] }
        expect(names).to contain_exactly("Published One", "Published Two")

        entry = props[:products].find { _1[:name] == "Published One" }
        expect(entry[:id]).to eq(published.external_id)
        expect(entry[:permalink]).to eq(published.general_permalink)
        expect(entry[:url]).to eq(published.long_url)
        expect(entry[:price_cents]).to eq(600)
        expect(entry[:currency_code]).to eq("usd")
        expect(entry[:price_formatted]).to eq(published.price_formatted_verbose)
        expect(entry).to have_key(:thumbnail_url)
      end

      it "uses the public permalink from the product URL" do
        published.update!(custom_permalink: "custom-product")
        entry = described_class.new(seller:).props[:products].find { _1[:name] == "Published One" }

        expect(entry[:permalink]).to eq("custom-product")
        expect(entry[:url]).to end_with("/l/custom-product")
      end

      it "uses the seller custom domain for product URLs when present" do
        entry = described_class.new(seller:, seller_custom_domain_url: "https://shop.example.com/").props[:products].find { _1[:name] == "Published One" }

        expect(entry[:url]).to eq("https://shop.example.com/l/#{published.general_permalink}")
      end

      it "excludes products hidden from profile tabs" do
        hidden = create(:product, user: seller, name: "Hidden Product")
        create(:seller_profile_products_section, seller:, shown_products: [hidden.id], add_new_products: false)
        Link.import(force: true, refresh: true)

        names = described_class.new(seller:).props[:products].map { _1[:name] }
        expect(names).not_to include("Hidden Product")
      end

      it "excludes unpublished, archived, and deleted products from profile sections" do
        draft = create(:product, user: seller, name: "Draft", purchase_disabled_at: Time.current)
        archived = create(:product, user: seller, name: "Archived", archived: true)
        deleted = create(:product, user: seller, name: "Deleted", deleted_at: Time.current)
        products_section.update!(shown_products: products_section.shown_products + [draft.id, archived.id, deleted.id])
        Link.import(force: true, refresh: true)

        names = props[:products].map { _1[:name] }
        expect(names).to contain_exactly("Published One", "Published Two")
      end

      it "excludes sold-out products hidden from public profile views" do
        sold_out = create(:product, user: seller, name: "Sold Out Product", hide_sold_out_variants: true, max_purchase_count: 0)
        products_section.update!(shown_products: products_section.shown_products + [sold_out.id])
        Link.import(force: true, refresh: true)

        names = described_class.new(seller:).props[:products].map { _1[:name] }
        expect(names).not_to include("Sold Out Product")
      end

      it "orders products by profile section layout" do
        expect(props[:products].first[:name]).to eq("Published Two")
      end

      it "orders product sections by profile tab order" do
        other_product = create(:product, user: seller, name: "Other Section Product")
        other_section = create(:seller_profile_products_section, seller:, shown_products: [other_product.id], add_new_products: false)
        seller.seller_profile.update!(
          json_data: {
            "tabs" => [
              { "name" => "Main", "sections" => [other_section.id, products_section.id] },
            ],
          },
        )
        Link.import(force: true, refresh: true)

        expect(described_class.new(seller:).props[:products].first[:name]).to eq("Other Section Product")
      end

      it "includes product sections from later profile tabs" do
        other_product = create(:product, user: seller, name: "Second Tab Product")
        other_section = create(:seller_profile_products_section, seller:, shown_products: [other_product.id], add_new_products: false)
        seller.seller_profile.update!(
          json_data: {
            "tabs" => [
              { "name" => "Main", "sections" => [products_section.id] },
              { "name" => "More", "sections" => [other_section.id] },
            ],
          },
        )
        Link.import(force: true, refresh: true)

        expect(described_class.new(seller:).props[:products].map { _1[:name] }).to include("Second Tab Product")
      end

      it "uses profile card pricing" do
        allow(ProductPresenter).to receive(:card_for_web).and_call_original
        allow(ProductPresenter).to receive(:card_for_web).with(product: published, show_seller: false, compute_description: false, compute_inventory: false).and_return(
          {
            price_cents: 450,
            currency_code: "usd",
            is_pay_what_you_want: false,
            recurrence: nil,
            duration_in_months: nil,
          }
        )

        entry = described_class.new(seller:).props[:products].find { _1[:name] == "Published One" }
        expect(entry[:price_cents]).to eq(450)
        expect(entry[:price_formatted]).to eq("$4.50")
      end

      it "uses the shared product sales count cache" do
        allow(ProductPresenter).to receive(:cached_sales_count).and_return(nil)
        allow(ProductPresenter).to receive(:cached_sales_count).with(published, latest_sale_id: nil).and_return(42)

        entry = described_class.new(seller:).props[:products].find { _1[:name] == "Published One" }
        expect(entry[:sales_count]).to eq(42)
      end

      it "respects the sales_count creator toggle" do
        published.update!(should_show_sales_count: false)
        entry = props[:products].find { _1[:name] == "Published One" }
        expect(entry[:sales_count]).to be_nil
      end

      it "caps the product list at PRODUCTS_LIMIT" do
        stub_const("#{described_class}::PRODUCTS_LIMIT", 1)
        expect(described_class.new(seller:).props[:products].size).to eq(1)
      end
    end
  end
end
