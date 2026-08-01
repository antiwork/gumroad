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
          avatar_url: ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png")
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
      purchases, creators = described_class.new(buyer).library_cards

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

      expect(creators).to eq([{ id: creator.external_id, name: creator.name }])
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
          avatar_url: ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png")
        }
      )
    end

    context "when a user has purchased a subscription multiple times" do
      let!(:purchase_2) do
        create(:membership_purchase, link: product, purchaser: buyer).tap { _1.create_url_redirect! }
      end

      before do
        product.update!(block_access_after_membership_cancellation: true)
        create(:recurring_membership_purchase, link: product, purchaser: buyer, subscription: purchase.subscription)
        create(:membership_purchase, link: product, purchaser: buyer).tap { _1.subscription.update!(cancelled_at: 1.day.ago) }
      end

      it "returns results for all live subscriptions and excludes cancelled ones when access is blocked" do
        purchases, creators = described_class.new(buyer).library_cards

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

        expect(creators).to eq([{ id: creator.external_id, name: creator.name }])
      end
    end

    context "when subscription is cancelled or ended" do
      context "when block_access_after_membership_cancellation is enabled (default)" do
        before do
          product.update!(block_access_after_membership_cancellation: true)
        end

        it "excludes cancelled subscriptions from library" do
          purchase.subscription.update!(cancelled_at: 1.day.ago)

          purchases, _ = described_class.new(buyer).library_cards
          expect(purchases).to be_empty
        end

        it "excludes ended subscriptions from library" do
          purchase.subscription.update!(ended_at: 1.day.ago)

          purchases, _ = described_class.new(buyer).library_cards
          expect(purchases).to be_empty
        end

        it "excludes failed subscriptions from library" do
          purchase.subscription.update!(failed_at: 1.day.ago)

          purchases, _ = described_class.new(buyer).library_cards
          expect(purchases).to be_empty
        end
      end

      context "when block_access_after_membership_cancellation is disabled" do
        before do
          product.update!(block_access_after_membership_cancellation: false)
        end

        it "includes cancelled subscriptions in library" do
          purchase.subscription.update!(cancelled_at: 1.day.ago)

          purchases, _ = described_class.new(buyer).library_cards
          expect(purchases.size).to eq(1)
          expect(purchases.first[:purchase][:id]).to eq(purchase.external_id)
        end

        it "includes ended subscriptions in library" do
          purchase.subscription.update!(ended_at: 1.day.ago)

          purchases, _ = described_class.new(buyer).library_cards
          expect(purchases.size).to eq(1)
          expect(purchases.first[:purchase][:id]).to eq(purchase.external_id)
        end

        it "includes failed subscriptions in library" do
          purchase.subscription.update!(failed_at: 1.day.ago)

          purchases, _ = described_class.new(buyer).library_cards
          expect(purchases.size).to eq(1)
          expect(purchases.first[:purchase][:id]).to eq(purchase.external_id)
        end
      end
    end

    context "when the original membership purchase was fully refunded" do
      def create_renewal(attributes = {})
        create(
          :membership_purchase,
          link: product,
          purchaser: buyer,
          email: buyer.email,
          subscription: purchase.subscription,
          is_original_subscription_purchase: false,
          succeeded_at: 1.day.ago,
          **attributes
        )
      end

      before do
        purchase.update!(stripe_refunded: true)
      end

      it "links the Library card to a later paid renewal" do
        renewal = create_renewal.tap(&:create_url_redirect!)

        purchases, _ = described_class.new(buyer).library_cards

        expect(purchases.first[:purchase][:id]).to eq(purchase.external_id)
        expect(purchases.first[:purchase][:download_url]).to eq(renewal.url_redirect.download_page_url)
        expect(purchases.first[:purchase][:download_url]).not_to eq(purchase.url_redirect.download_page_url)
      end

      it "does not publish the refunded URL when there is no paid renewal" do
        purchases, _ = described_class.new(buyer).library_cards

        expect(purchases.first[:purchase][:id]).to eq(purchase.external_id)
        expect(purchases.first[:purchase][:download_url]).to be_nil
      end

      it "skips a fully refunded renewal" do
        create_renewal(stripe_refunded: true).tap(&:create_url_redirect!)

        purchases, _ = described_class.new(buyer).library_cards

        expect(purchases.first[:purchase][:download_url]).to be_nil
      end

      it "skips a renewal with an unreversed chargeback" do
        create_renewal(chargeback_date: Time.current).tap(&:create_url_redirect!)

        purchases, _ = described_class.new(buyer).library_cards

        expect(purchases.first[:purchase][:download_url]).to be_nil
      end

      it "allows partially refunded renewals and reversed chargebacks" do
        renewal = create_renewal(
          stripe_partially_refunded: true,
          chargeback_date: 2.days.ago,
          chargeback_reversed: true
        ).tap(&:create_url_redirect!)

        purchases, _ = described_class.new(buyer).library_cards

        expect(purchases.first[:purchase][:download_url]).to eq(renewal.url_redirect.download_page_url)
      end

      it "falls back to an older eligible redirect" do
        eligible_renewal = create_renewal(succeeded_at: 3.days.ago).tap(&:create_url_redirect!)
        create_renewal(succeeded_at: 2.days.ago, stripe_refunded: true).tap(&:create_url_redirect!)
        create_renewal(succeeded_at: 2.days.ago, is_access_revoked: true).tap(&:create_url_redirect!)
        create_renewal(succeeded_at: 1.day.ago)

        purchases, _ = described_class.new(buyer).library_cards

        expect(purchases.first[:purchase][:download_url]).to eq(eligible_renewal.url_redirect.download_page_url)
      end

      it "falls back past newer purchases for another buyer or product" do
        eligible_renewal = create_renewal(succeeded_at: 3.days.ago, email: "updated@example.com").tap(&:create_url_redirect!)
        create_renewal(succeeded_at: 2.days.ago, purchaser: create(:user)).tap(&:create_url_redirect!)
        create_renewal(succeeded_at: 1.day.ago, link: create(:membership_product, user: creator)).tap(&:create_url_redirect!)

        purchases, _ = described_class.new(buyer).library_cards

        expect(purchases.first[:purchase][:download_url]).to eq(eligible_renewal.url_redirect.download_page_url)
      end

      it "does not link a transferred card to a renewal left on the previous owner" do
        previous_owner = create(:user)
        purchase.subscription.update!(user: previous_owner)
        create_renewal(purchaser: previous_owner, email: previous_owner.email).tap(&:create_url_redirect!)

        purchases, _ = described_class.new(buyer).library_cards

        # UrlRedirectsController#check_permissions authorizes against the rendered purchase's
        # purchaser, so this renewal's redirect would bounce the viewer to purchaser verification
        # keyed to the previous owner's email. No link beats a link that cannot resolve.
        expect(purchases.first[:purchase][:id]).to eq(purchase.external_id)
        expect(purchases.first[:purchase][:download_url]).to be_nil
      end

      it "does not select another user's renewal on the viewer's own subscription" do
        other_user = create(:user)
        create_renewal(purchaser: other_user, email: other_user.email).tap(&:create_url_redirect!)

        purchases, _ = described_class.new(buyer).library_cards

        expect(purchases.first[:purchase][:download_url]).to be_nil
      end

      it "ignores unsuccessful renewal attempts" do
        create_renewal(purchase_state: "failed").tap(&:create_url_redirect!)
        create_renewal(purchase_state: "in_progress").tap(&:create_url_redirect!)

        purchases, _ = described_class.new(buyer).library_cards

        expect(purchases.first[:purchase][:download_url]).to be_nil
      end

      it "uses the newest renewal deterministically when timestamps match" do
        succeeded_at = 1.day.ago
        create_renewal(succeeded_at:).tap(&:create_url_redirect!)
        newest_renewal = create_renewal(succeeded_at:).tap(&:create_url_redirect!)

        purchases, _ = described_class.new(buyer).library_cards

        expect(purchases.first[:purchase][:download_url]).to eq(newest_renewal.url_redirect.download_page_url)
      end

      it "loads replacement redirects in one query for multiple Library cards" do
        other_purchase = create(:membership_purchase, link: product, purchaser: buyer, stripe_refunded: true)
        other_purchase.create_url_redirect!
        create_renewal.tap(&:create_url_redirect!)
        create(
          :membership_purchase,
          link: product,
          purchaser: buyer,
          email: buyer.email,
          subscription: other_purchase.subscription,
          is_original_subscription_purchase: false,
          succeeded_at: 1.day.ago
        ).tap(&:create_url_redirect!)
        replacement_queries = []
        subscription_probes = []
        callback = lambda do |*, payload|
          sql = payload[:sql]
          replacement_queries << sql if sql.include?("LEFT OUTER JOIN `url_redirects`") && sql.include?("`purchases`.`subscription_id`")
          subscription_probes << sql if sql.include?("FROM `subscriptions`") && sql.include?("LIMIT 1")
        end

        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          described_class.new(buyer).library_cards
        end

        expect(replacement_queries.size).to eq(1)
        expect(subscription_probes).to be_empty
      end
    end

    context "when the user has a gifted membership purchase" do
      let(:gifted_product) { create(:membership_product, name: "Gifted Membership", user: creator) }
      let(:subscription) { create(:subscription, link: gifted_product, user: buyer) }
      let!(:gift_receiver_purchase) do
        create(:purchase,
               :gift_receiver,
               link: gifted_product,
               purchaser: buyer,
               subscription: subscription,
               is_original_subscription_purchase: false).tap { _1.create_url_redirect! }
      end

      it "includes gifted membership purchases in the library" do
        purchases, _ = described_class.new(buyer).library_cards

        gift_purchase = purchases.find { _1[:purchase][:id] == gift_receiver_purchase.external_id }
        expect(gift_purchase[:purchase][:download_url]).to eq(gift_receiver_purchase.url_redirect.download_page_url)
      end

      it "links a refunded gift-receiver card to the giftee's paid renewal" do
        gift_subscription = create(:subscription, link: gifted_product, user: buyer)
        gifter = create(
          :membership_purchase,
          link: gifted_product,
          subscription: gift_subscription,
          purchaser: create(:user),
          is_gift_sender_purchase: true,
          succeeded_at: 3.days.ago
        )
        refunded_gift_purchase = create(
          :purchase,
          :gift_receiver,
          link: gifted_product,
          purchaser: buyer,
          subscription: gift_subscription,
          is_original_subscription_purchase: false
        ).tap(&:create_url_redirect!)
        create(
          :gift,
          link: gifted_product,
          gifter_purchase: gifter,
          giftee_purchase: refunded_gift_purchase,
          gifter_email: gifter.email,
          giftee_email: buyer.email
        )
        gift_subscription.reload
        renewal = create(
          :membership_purchase,
          link: gifted_product,
          subscription: gift_subscription,
          purchaser: buyer,
          email: buyer.email,
          is_original_subscription_purchase: false,
          succeeded_at: 1.day.ago
        ).tap(&:create_url_redirect!)
        gifter.reload.mark_giftee_purchase_as_refunded
        refunded_gift_purchase.reload

        purchases, _ = described_class.new(buyer).library_cards

        expect(refunded_gift_purchase).to be_stripe_refunded
        gift_purchase = purchases.find { _1[:purchase][:id] == refunded_gift_purchase.external_id }
        expect(gift_purchase[:purchase][:download_url]).to eq(renewal.url_redirect.download_page_url)
        expect(gifter.url_redirect).to be_nil
      end
    end

    describe "has_third_party_analytics" do
      it "detects product-level receipt analytics" do
        create(:third_party_analytic, user: creator, link: product, location: "receipt", analytics_code: "<script>test</script>")

        purchases, _ = described_class.new(buyer).library_cards
        expect(purchases.first[:product][:has_third_party_analytics]).to eq(true)
      end

      it "detects product-level analytics with 'all' location" do
        create(:third_party_analytic, user: creator, link: product, location: "all", analytics_code: "<script>test</script>")

        purchases, _ = described_class.new(buyer).library_cards
        expect(purchases.first[:product][:has_third_party_analytics]).to eq(true)
      end

      it "detects user-level universal receipt analytics" do
        create(:third_party_analytic, user: creator, link: nil, location: "receipt", analytics_code: "<script>test</script>")

        purchases, _ = described_class.new(buyer).library_cards
        expect(purchases.first[:product][:has_third_party_analytics]).to eq(true)
      end

      it "ignores deleted analytics" do
        create(:third_party_analytic, user: creator, link: product, location: "receipt", analytics_code: "<script>test</script>", deleted_at: 1.day.ago)

        purchases, _ = described_class.new(buyer).library_cards
        expect(purchases.first[:product][:has_third_party_analytics]).to eq(false)
      end

      it "ignores analytics for non-receipt locations" do
        create(:third_party_analytic, user: creator, link: product, location: "product", analytics_code: "<script>test</script>")

        purchases, _ = described_class.new(buyer).library_cards
        expect(purchases.first[:product][:has_third_party_analytics]).to eq(false)
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

      context "when the bundle has no alive member products" do
        let(:memberless_bundle) do
          create(:product, :bundle, name: "Memberless Bundle", user: creator).tap do |bundle|
            bundle.bundle_products.each(&:mark_deleted!)
          end
        end
        let(:memberless_purchase) { create(:purchase, purchaser: buyer, link: memberless_bundle) }

        before do
          memberless_purchase.create_artifacts_and_send_receipt!
        end

        it "renders the bundle itself rather than hiding it behind members that do not exist" do
          purchases, _, bundles = described_class.new(buyer).library_cards

          row = purchases.find { _1[:purchase][:id] == memberless_purchase.external_id }
          expect(row).to be_present
          expect(row[:purchase][:is_bundle_purchase]).to eq(false)
          expect(row[:product][:name]).to eq("Memberless Bundle")
          expect(row[:purchase][:download_url]).to eq(memberless_purchase.url_redirect.download_page_url)

          # Nothing filters to it, so it must not offer itself as a bundle filter option.
          expect(bundles.map { _1[:id] }).to_not include(memberless_bundle.external_id)
        end
      end

      context "when every member purchase is excluded from the library" do
        it "renders the bundle itself so the buyer keeps a row for the purchase" do
          purchase1.product_purchases.each { _1.update!(is_deleted_by_buyer: true) }

          purchases, _, _ = described_class.new(buyer).library_cards

          row = purchases.find { _1[:purchase][:id] == purchase1.external_id }
          expect(row).to be_present
          expect(row[:purchase][:is_bundle_purchase]).to eq(false)
        end
      end
    end
  end
end
