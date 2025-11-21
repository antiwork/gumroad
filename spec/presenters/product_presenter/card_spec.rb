# frozen_string_literal: true

require "spec_helper"

describe ProductPresenter::Card do
  include Rails.application.routes.url_helpers

  let(:request) { instance_double(ActionDispatch::Request, host: "test.gumroad.com", host_with_port: "test.gumroad.com:1234", protocol: "http") }
  let(:creator) { create(:user, name: "Testy", username: "testy") }
  let(:product) { create(:product, unique_permalink: "test", name: "hello", user: creator) }

  describe "#for_web" do
    context "digital product" do
      it "returns the necessary properties for a product card" do
        data = described_class.new(product:).for_web(request:, recommended_by: "discover")

        expect(data).to eq(
          {
            id: product.external_id,
            permalink: "test",
            name: "hello",
            seller: {
              id: creator.external_id,
              name: "Testy",
              profile_url: creator.profile_url(recommended_by: "discover"),
              avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png")
            },
            description: product.plaintext_description.truncate(100),
            ratings: { count: 0, average: 0 },
            currency_code: Currency::USD,
            price_cents: 100,
            thumbnail_url: nil,
            native_type: Link::NATIVE_TYPE_DIGITAL,
            is_pay_what_you_want: false,
            is_sales_limited: false,
            duration_in_months: nil,
            recurrence: nil,
            url: product.long_url(recommended_by: "discover"),
            quantity_remaining: nil
          }
        )
      end

      it "returns the URL with the offer code" do
        data = described_class.new(product:).for_web(request:, recommended_by: "discover", offer_code: "BLACKFRIDAY2025")
        expect(data[:url]).to include("code=BLACKFRIDAY2025")
      end


      it "does not return the URL of a deleted thumbnail" do
        create(:thumbnail, product:)
        result = described_class.new(product:).for_web
        expect(result[:thumbnail_url]).to be_present

        product.thumbnail.mark_deleted!
        product.reload
        result = described_class.new(product:).for_web
        expect(result[:thumbnail_url]).to eq(nil)
      end

      it "includes description when compute_description is true by default" do
        result = described_class.new(product:).for_web

        expect(result[:description]).to eq(product.plaintext_description.truncate(100))
      end

      it "includes description when compute_description is explicitly true" do
        result = described_class.new(product:).for_web(compute_description: true)

        expect(result[:description]).to eq(product.plaintext_description.truncate(100))
      end

      it "excludes description when compute_description is false" do
        result = described_class.new(product:).for_web(compute_description: false)

        expect(result).not_to have_key(:description)
      end
    end

    context "membership product" do
      let(:product) do
        recurrence_price_values = [
          {
            "monthly" => { enabled: true, price: 10 },
            "yearly" => { enabled: true, price: 100 }
          },
          {
            "monthly" => { enabled: true, price: 2.99 },
            "yearly" => { enabled: true, price: 19.99 }
          }
        ]
        create(:membership_product_with_preset_tiered_pricing, user: creator, recurrence_price_values:, subscription_duration: "yearly")
      end

      it "includes the lowest tier price for the default subscription duration" do
        data = described_class.new(product:).for_web
        expect(data[:price_cents]).to eq 19_99
      end
    end
  end

  describe "#for_email" do
    it "returns the necessary properties for an email product card" do
      expect(described_class.new(product:).for_email).to eq(
        {
          name: product.name,
          thumbnail_url: ActionController::Base.helpers.asset_url("native_types/thumbnails/digital.png"),
          url: short_link_url(product.general_permalink, host: "http://#{creator.username}.test.gumroad.com:31337"),
          seller: {
            name: creator.name,
            profile_url: creator.profile_url,
            avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
          },
        }
      )
    end
  end
end
