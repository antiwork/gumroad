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

      it "lists the seller's published products with public fields" do
        names = props[:products].map { _1[:name] }
        expect(names).to contain_exactly("Published One", "Published Two")

        entry = props[:products].find { _1[:name] == "Published One" }
        expect(entry[:id]).to eq(published.external_id)
        expect(entry[:permalink]).to eq(published.unique_permalink)
        expect(entry[:url]).to eq(published.long_url)
        expect(entry[:price_cents]).to eq(600)
        expect(entry[:currency_code]).to eq("usd")
        expect(entry[:price_formatted]).to eq(published.price_formatted_verbose)
        expect(entry).to have_key(:thumbnail_url)
      end

      it "excludes unpublished, archived, and deleted products" do
        create(:product, user: seller, name: "Draft", purchase_disabled_at: Time.current)
        create(:product, user: seller, name: "Archived", archived: true)
        create(:product, user: seller, name: "Deleted", deleted_at: Time.current)

        names = props[:products].map { _1[:name] }
        expect(names).to contain_exactly("Published One", "Published Two")
      end

      it "orders products newest-first" do
        expect(props[:products].first[:name]).to eq("Published Two")
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
