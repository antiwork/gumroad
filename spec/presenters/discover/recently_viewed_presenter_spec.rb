# frozen_string_literal: true

require "spec_helper"

describe Discover::RecentlyViewedPresenter do
  let(:user) { create(:user) }
  let(:browser_guid) { SecureRandom.uuid }
  let(:request) { instance_double(ActionDispatch::Request, host: "test.gumroad.com", host_with_port: "test.gumroad.com:1234", protocol: "http", cookie_jar: {}, remote_ip: "0.0.0.0") }
  let(:presenter) { described_class.new(user:, browser_guid:, request:) }

  let!(:product) { create(:product, :recommendable, name: "Viewed Product") }
  let!(:other_product) { create(:product, :recommendable, name: "Other Product") }

  before do
    Link.import(force: true, refresh: true)
  end

  describe "#props" do
    it "returns nil when there is no identity" do
      expect(described_class.new(user: nil, browser_guid: nil, request:).props).to be_nil
    end

    it "returns nil when the visitor has no views" do
      expect(presenter.props).to be_nil
    end

    context "when the user has viewed products" do
      before do
        add_page_view(product, 2.days.ago.iso8601, user_id: user.id)
        ProductPageView.__elasticsearch__.refresh_index!
      end

      it "returns cards for the viewed products only, tagged as recently_viewed" do
        result = presenter.props

        expect(result[:products].map { _1[:name] }).to eq(["Viewed Product"])
        expect(result[:products].first[:url]).to include("recommended_by=recently_viewed")
        expect(result[:products].first[:viewed_at]).to be_present
      end

      it "ignores views older than 30 days" do
        add_page_view(other_product, 31.days.ago.iso8601, user_id: user.id)
        ProductPageView.__elasticsearch__.refresh_index!

        expect(presenter.props[:products].map { _1[:name] }).to eq(["Viewed Product"])
      end

      it "orders products by most recent view and deduplicates repeat views" do
        add_page_view(other_product, 1.day.ago.iso8601, user_id: user.id)
        add_page_view(product, 3.days.ago.iso8601, user_id: user.id)
        ProductPageView.__elasticsearch__.refresh_index!

        expect(presenter.props[:products].map { _1[:name] }).to eq(["Other Product", "Viewed Product"])
      end

      it "hides products rated as adult unless included" do
        nsfw = create(:product, :recommendable, name: "NSFW Product", is_adult: true)
        Link.import(force: true, refresh: true)
        add_page_view(nsfw, 1.day.ago.iso8601, user_id: user.id)
        ProductPageView.__elasticsearch__.refresh_index!

        expect(presenter.props[:products].map { _1[:name] }).to eq(["Viewed Product"])

        including = described_class.new(user:, browser_guid:, request:, include_rated_as_adult: true)
        expect(including.props[:products].map { _1[:name] }).to eq(["NSFW Product", "Viewed Product"])
      end

      it "excludes products that are no longer recommendable" do
        unlisted = create(:product, name: "Unlisted Product")
        Link.import(force: true, refresh: true)
        add_page_view(unlisted, 1.day.ago.iso8601, user_id: user.id)
        ProductPageView.__elasticsearch__.refresh_index!

        expect(presenter.props[:products].map { _1[:name] }).to eq(["Viewed Product"])
      end
    end

    context "when anonymous" do
      before do
        add_page_view(product, 1.day.ago.iso8601, browser_guid:)
        ProductPageView.__elasticsearch__.refresh_index!
      end

      it "returns views matching the browser guid without a user" do
        result = described_class.new(user: nil, browser_guid:, request:).props

        expect(result[:products].map { _1[:name] }).to eq(["Viewed Product"])
      end

      it "does not return another browser's views" do
        result = described_class.new(user: nil, browser_guid: SecureRandom.uuid, request:).props

        expect(result).to be_nil
      end

      it "derives a stable anonymous_key from the browser guid and omits it for logged-in users" do
        anon_result = described_class.new(user: nil, browser_guid:, request:).props
        expect(anon_result[:anonymous_key]).to eq(Digest::SHA256.hexdigest(browser_guid)[0, 16])

        add_page_view(product, 1.day.ago.iso8601, user_id: user.id)
        ProductPageView.__elasticsearch__.refresh_index!
        expect(presenter.props[:anonymous_key]).to be_nil
      end

      it "gives different browser guids different anonymous keys" do
        other_guid = SecureRandom.uuid
        add_page_view(product, 1.day.ago.iso8601, browser_guid: other_guid)
        ProductPageView.__elasticsearch__.refresh_index!

        key_a = described_class.new(user: nil, browser_guid:, request:).props[:anonymous_key]
        key_b = described_class.new(user: nil, browser_guid: other_guid, request:).props[:anonymous_key]
        expect(key_a).not_to eq(key_b)
      end
    end
  end
end
