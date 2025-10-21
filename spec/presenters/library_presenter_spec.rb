# frozen_string_literal: true

require "spec_helper"

describe LibraryPresenter do
  include Rails.application.routes.url_helpers

  let(:creator) { create(:user, name: "Testy", username: "testy") }
  let(:product) { create(:membership_product, unique_permalink: "test", name: "hello", user: creator) }
  let(:buyer) { create(:user, name: "Buyer", username: "buyer") }
  let(:purchase) { create(:membership_purchase, link: product, purchaser: buyer) }

  describe "#library_cards" do
    let(:product_details) do
      {
        name: "hello",
        creator_id: creator.external_id,
        creator: {
          name: "Testy",
          profile_url: creator.profile_url(recommended_by: "library"),
          avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png")
        },
        thumbnail_url: nil,
        native_type: "membership",
        updated_at: product.created_at,
        permalink: product.unique_permalink,
        has_third_party_analytics: false,
      }
    end

    before do
      purchase.create_url_redirect!
    end

    it "returns all necessary properties for library page" do
      purchases, creator_counts = described_class.new(buyer).library_cards

      expect(purchases).to eq([
                                product: product_details,
                                purchase: {
                                  id: purchase.external_id,
                                  email: purchase.email,
                                  is_archived: false,
                                  download_url: purchase.url_redirect.download_page_url,
                                  bundle_id: nil,
                                  variants: "Untitled",
                                  is_bundle_purchase: false,
                                }])

      expect(creator_counts).to eq([{ count: 1, id: creator.external_id, name: creator.name }])
    end

    it "does not return the URL of a deleted thumbnail" do
      create(:thumbnail, product:)
      purchases, _ = described_class.new(buyer).library_cards
      expect(purchases[0][:product][:thumbnail_url]).to be_present

      product.thumbnail.mark_deleted!
      purchases, _ = described_class.new(buyer).library_cards
      expect(purchases[0][:product][:thumbnail_url]).to eq(nil)
    end

    it "handles users without a username set" do
      creator.update(username: nil)
      purchases, _ = described_class.new(buyer).library_cards
      expect(purchases[0][:creator]).to be_nil
    end

    it "handles users without a name set" do
      creator.update(name: nil)
      purchases, _ = described_class.new(buyer).library_cards

      expect(purchases[0][:product][:creator]).to eq(
        {
          name: creator.username,
          profile_url: creator.profile_url(recommended_by: "library"),
          avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png")
        }
      )
    end

    context "when a user has purchased a subscription multiple times" do
      let!(:purchase_2) do
        create(:membership_purchase, link: product, purchaser: buyer).tap { _1.create_url_redirect! }
      end

      before do
        create(:recurring_membership_purchase, link: product, purchaser: buyer, subscription: purchase.subscription)
        create(:membership_purchase, link: product, purchaser: buyer).tap { _1.subscription.update!(cancelled_at: 1.day.ago) }
      end

      it "returns results for all live subscriptions" do
        purchases, creator_counts = described_class.new(buyer).library_cards

        expect(purchases).to eq([
                                  {
                                    product: product_details,
                                    purchase: {
                                      id: purchase_2.external_id,
                                      email: purchase_2.email,
                                      is_archived: false,
                                      download_url: purchase_2.url_redirect.download_page_url,
                                      bundle_id: nil,
                                      variants: "Untitled",
                                      is_bundle_purchase: false,
                                    },
                                  },
                                  {
                                    product: product_details,
                                    purchase: {
                                      id: purchase.external_id,
                                      email: purchase.email,
                                      is_archived: false,
                                      download_url: purchase.url_redirect.download_page_url,
                                      bundle_id: nil,
                                      variants: "Untitled",
                                      is_bundle_purchase: false,
                                    },
                                  },
                                ])

        expect(creator_counts).to eq([{ count: 1, id: creator.external_id, name: creator.name }])
      end
    end

    describe "bundle purchase" do
      let(:purchase1) { create(:purchase, purchaser: buyer, link: create(:product, :bundle)) }
      let(:purchase2) { create(:purchase, purchaser: buyer, link: create(:product, :bundle)) }

      before do
        purchase1.create_artifacts_and_send_receipt!
        purchase2.create_artifacts_and_send_receipt!
      end

      it "includes the bundle attributes" do
        purchases, _, bundles = described_class.new(buyer).library_cards

        expect(purchases.first[:purchase][:id]).to eq(purchase2.product_purchases.second.external_id)
        expect(purchases.first[:purchase][:bundle_id]).to eq(purchase2.link.external_id)
        expect(purchases.first[:purchase][:is_bundle_purchase]).to eq(false)

        expect(purchases.second[:purchase][:id]).to eq(purchase2.product_purchases.first.external_id)
        expect(purchases.second[:purchase][:bundle_id]).to eq(purchase2.link.external_id)
        expect(purchases.second[:purchase][:is_bundle_purchase]).to eq(false)

        expect(purchases.third[:purchase][:id]).to eq(purchase2.external_id)
        expect(purchases.third[:purchase][:bundle_id]).to be_nil
        expect(purchases.third[:purchase][:is_bundle_purchase]).to eq(true)

        expect(bundles).to eq(
          [
            { id: purchase2.link.external_id, label: "Bundle" },
            { id: purchase1.link.external_id, label: "Bundle" },
          ]
        )
      end
    end
  end
end
