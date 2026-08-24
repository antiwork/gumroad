# frozen_string_literal: true

require "spec_helper"

describe LibraryPresenter do
  include Rails.application.routes.url_helpers

  let(:creator) { create(:user, name: "Testy", username: "testy") }
  let(:product) { create(:membership_product, unique_permalink: "test", name: "hello", user: creator) }
  let(:buyer) { create(:user, name: "Buyer", username: "buyer") }
  let(:purchase) { create(:membership_purchase, link: product, purchaser: buyer) }

  def library_props(**params)
    described_class.new(buyer).library_props(**params)
  end

  def results(**params)
    library_props(**params)[:results]
  end

  describe "#library_props" do
    let(:product_details) do
      {
        name: "hello",
        creator: {
          name: "Testy",
          profile_url: creator.profile_url(recommended_by: "library"),
          avatar_url: ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png")
        },
        thumbnail_url: nil,
        native_type: "membership",
      }
    end

    before do
      purchase.create_url_redirect!
    end

    it "returns all necessary properties for the library page" do
      props = library_props

      expect(props[:results]).to eq([
                                      product: product_details,
                                      purchase: {
                                        id: purchase.external_id,
                                        is_archived: false,
                                        download_url: purchase.url_redirect.download_page_url,
                                        variants: "Untitled",
                                      }])
      expect(props[:pagination]).to eq(page: 1, pages: 1, from: 1, to: 1, count: 1)
      expect(props[:creators]).to eq([{ id: creator.external_id, name: creator.name, count: 1 }])
      expect(props[:bundles]).to eq([])
      expect(props[:bundle_downloads]).to eq([])
      expect(props[:archived_count]).to eq(0)
      expect(props[:unarchived_count]).to eq(1)
      expect(props[:search]).to eq(
        sort: "recently_updated",
        query: "",
        creators: [],
        bundles: [],
        show_archived_only: false
      )
    end

    it "does not return the URL of a deleted thumbnail" do
      create(:thumbnail, product:)
      expect(results[0][:product][:thumbnail_url]).to be_present

      product.thumbnail.mark_deleted!
      expect(results[0][:product][:thumbnail_url]).to eq(nil)
    end

    it "still renders a byline for users without a username, whose username falls back to their external id" do
      creator.update!(username: nil)

      expect(results[0][:product][:creator]).to eq(
        {
          name: "Testy",
          profile_url: creator.profile_url(recommended_by: "library"),
          avatar_url: ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png")
        }
      )
    end

    it "handles users without a name set" do
      creator.update(name: nil)

      expect(results[0][:product][:creator]).to eq(
        {
          name: creator.username,
          profile_url: creator.profile_url(recommended_by: "library"),
          avatar_url: ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png")
        }
      )
    end

    describe "pagination" do
      let!(:purchases) do
        create_list(:purchase, 16, purchaser: buyer) # plus the membership purchase from the outer `before`
      end

      it "returns 15 results per page with pagination metadata" do
        props = library_props

        expect(props[:results].size).to eq(15)
        expect(props[:pagination]).to eq(page: 1, pages: 2, from: 1, to: 15, count: 17)
      end

      it "returns the requested page" do
        props = library_props(page: "2")

        expect(props[:results].size).to eq(2)
        expect(props[:pagination]).to eq(page: 2, pages: 2, from: 16, to: 17, count: 17)
      end

      it "does not duplicate or drop a purchase across page boundaries" do
        page_1_ids = library_props(page: "1")[:results].map { _1[:purchase][:id] }
        page_2_ids = library_props(page: "2")[:results].map { _1[:purchase][:id] }

        expect(page_1_ids & page_2_ids).to be_empty
        expect((page_1_ids + page_2_ids).to_set).to eq((purchases.map(&:external_id) + [purchase.external_id]).to_set)
      end

      it "serves the last page when the requested page is past the end" do
        props = library_props(page: "99")

        expect(props[:pagination][:page]).to eq(2)
        expect(props[:results].size).to eq(2)
      end

      it "treats a missing or malformed page as the first page" do
        expect(library_props(page: nil)[:pagination][:page]).to eq(1)
        expect(library_props(page: "garbage")[:pagination][:page]).to eq(1)
        expect(library_props(page: "-3")[:pagination][:page]).to eq(1)
      end
    end

    describe "sorting" do
      let!(:recently_updated) do
        create(:purchase, purchaser: buyer, link: create(:product, name: "Updated", created_at: 3.days.ago, content_updated_at: 1.hour.ago))
      end
      let!(:newest_purchase) do
        create(:purchase, purchaser: buyer, link: create(:product, name: "Newest", created_at: 2.days.ago))
      end

      before do
        product.update!(created_at: 5.days.ago)
      end

      it "sorts by content updated time, falling back to product creation time, newest first, by default" do
        names = results.map { _1[:product][:name] }
        expect(names).to eq(["Updated", "Newest", "hello"])
      end

      it "sorts by purchase recency when purchase_date is requested" do
        names = results(sort: "purchase_date").map { _1[:product][:name] }
        expect(names).to eq(["Newest", "Updated", "hello"])
      end

      it "falls back to the default sort for unknown values" do
        props = library_props(sort: "nonsense")
        expect(props[:search][:sort]).to eq("recently_updated")
      end
    end

    describe "searching" do
      let!(:other_purchase) do
        other_creator = create(:user, name: "Wombat Workshop", username: "wombat")
        create(:purchase, purchaser: buyer, link: create(:product, name: "Standalone Asset", user: other_creator))
      end

      it "matches product names case-insensitively" do
        matches = results(query: "HELLO")
        expect(matches.map { _1[:product][:name] }).to eq(["hello"])
      end

      it "matches creator names" do
        matches = results(query: "Wombat")
        expect(matches.map { _1[:product][:name] }).to eq(["Standalone Asset"])
      end

      it "matches the creator's username when they have no name" do
        other_purchase.link.user.update!(name: nil)
        matches = results(query: "wombat")
        expect(matches.map { _1[:product][:name] }).to eq(["Standalone Asset"])
      end

      it "matches the name of a creator without a username, whose byline still renders their name" do
        other_purchase.link.user.update!(username: nil)
        matches = results(query: "Wombat")
        expect(matches.map { _1[:product][:name] }).to eq(["Standalone Asset"])
      end

      it "returns pagination reflecting the filtered count" do
        expect(library_props(query: "hello")[:pagination][:count]).to eq(1)
      end

      it "does not restrict the creators filter list" do
        expect(library_props(query: "hello")[:creators].size).to eq(2)
      end
    end

    describe "creator filter" do
      let(:other_creator) { create(:user, name: "Other", username: "other") }
      let!(:other_purchase) { create(:purchase, purchaser: buyer, link: create(:product, user: other_creator, name: "Other product")) }

      it "restricts results to the selected creators" do
        matches = results(creator_ids: [other_creator.external_id])
        expect(matches.map { _1[:product][:name] }).to eq(["Other product"])
      end

      it "supports multiple selected creators" do
        matches = results(creator_ids: [other_creator.external_id, creator.external_id])
        expect(matches.size).to eq(2)
      end

      it "matches nothing when no selected id resolves to a creator" do
        expect(results(creator_ids: ["garbage"])).to be_empty
      end
    end

    describe "archived purchases" do
      let!(:archived_purchase) { create(:purchase, purchaser: buyer, is_archived: true, link: create(:product, name: "Archived product")) }

      it "excludes archived purchases by default and includes only them on the archived tab" do
        expect(results.map { _1[:product][:name] }).to eq(["hello"])
        expect(results(show_archived_only: true).map { _1[:product][:name] }).to eq(["Archived product"])
      end

      it "counts archived and unarchived purchases" do
        # Asymmetric on purpose: with 1/1 the two counts are indistinguishable, so swapping the
        # scopes would survive this example.
        create(:purchase, purchaser: buyer, is_archived: true, link: create(:product, name: "Second archived product"))

        props = library_props
        expect(props[:archived_count]).to eq(2)
        expect(props[:unarchived_count]).to eq(1)
      end

      it "scopes the creators list and counts to the current tab" do
        expect(library_props[:creators]).to eq([{ id: creator.external_id, name: "Testy", count: 1 }])
        expect(library_props(show_archived_only: true)[:creators])
          .to eq([{ id: archived_purchase.link.user.external_id, name: archived_purchase.link.user.username, count: 1 }])
      end
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
        props = library_props

        expect(props[:results]).to eq([
                                        {
                                          product: product_details,
                                          purchase: {
                                            id: purchase_2.external_id,
                                            is_archived: false,
                                            download_url: purchase_2.url_redirect.download_page_url,
                                            variants: "Untitled",
                                          },
                                        },
                                        {
                                          product: product_details,
                                          purchase: {
                                            id: purchase.external_id,
                                            is_archived: false,
                                            download_url: purchase.url_redirect.download_page_url,
                                            variants: "Untitled",
                                          },
                                        },
                                      ])

        expect(props[:creators]).to eq([{ id: creator.external_id, name: creator.name, count: 2 }])
      end
    end

    context "when subscription is cancelled or ended" do
      context "when block_access_after_membership_cancellation is enabled (default)" do
        before do
          product.update!(block_access_after_membership_cancellation: true)
        end

        it "excludes cancelled subscriptions from library" do
          purchase.subscription.update!(cancelled_at: 1.day.ago)

          expect(results).to be_empty
        end

        it "excludes ended subscriptions from library" do
          purchase.subscription.update!(ended_at: 1.day.ago)

          expect(results).to be_empty
        end

        it "excludes failed subscriptions from library" do
          purchase.subscription.update!(failed_at: 1.day.ago)

          expect(results).to be_empty
        end

        it "excludes inaccessible purchases from every count and the creators list" do
          purchase.subscription.update!(cancelled_at: 1.day.ago)

          props = library_props
          expect(props[:pagination][:count]).to eq(0)
          expect(props[:unarchived_count]).to eq(0)
          expect(props[:creators]).to be_empty
        end
      end

      context "when block_access_after_membership_cancellation is disabled" do
        before do
          product.update!(block_access_after_membership_cancellation: false)
        end

        it "includes cancelled subscriptions in library" do
          purchase.subscription.update!(cancelled_at: 1.day.ago)

          expect(results.size).to eq(1)
          expect(results.first[:purchase][:id]).to eq(purchase.external_id)
        end

        it "includes ended subscriptions in library" do
          purchase.subscription.update!(ended_at: 1.day.ago)

          expect(results.size).to eq(1)
          expect(results.first[:purchase][:id]).to eq(purchase.external_id)
        end

        it "includes failed subscriptions in library" do
          purchase.subscription.update!(failed_at: 1.day.ago)

          expect(results.size).to eq(1)
          expect(results.first[:purchase][:id]).to eq(purchase.external_id)
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

        expect(results.first[:purchase][:id]).to eq(purchase.external_id)
        expect(results.first[:purchase][:download_url]).to eq(renewal.url_redirect.download_page_url)
        expect(results.first[:purchase][:download_url]).not_to eq(purchase.url_redirect.download_page_url)
      end

      it "does not publish the refunded URL when there is no paid renewal" do
        expect(results.first[:purchase][:id]).to eq(purchase.external_id)
        expect(results.first[:purchase][:download_url]).to be_nil
      end

      it "skips a fully refunded renewal" do
        create_renewal(stripe_refunded: true).tap(&:create_url_redirect!)

        expect(results.first[:purchase][:download_url]).to be_nil
      end

      it "skips a renewal with an unreversed chargeback" do
        create_renewal(chargeback_date: Time.current).tap(&:create_url_redirect!)

        expect(results.first[:purchase][:download_url]).to be_nil
      end

      it "allows partially refunded renewals and reversed chargebacks" do
        renewal = create_renewal(
          stripe_partially_refunded: true,
          chargeback_date: 2.days.ago,
          chargeback_reversed: true
        ).tap(&:create_url_redirect!)

        expect(results.first[:purchase][:download_url]).to eq(renewal.url_redirect.download_page_url)
      end

      it "falls back to an older eligible redirect" do
        eligible_renewal = create_renewal(succeeded_at: 3.days.ago).tap(&:create_url_redirect!)
        create_renewal(succeeded_at: 2.days.ago, stripe_refunded: true).tap(&:create_url_redirect!)
        create_renewal(succeeded_at: 2.days.ago, is_access_revoked: true).tap(&:create_url_redirect!)
        create_renewal(succeeded_at: 1.day.ago)

        expect(results.first[:purchase][:download_url]).to eq(eligible_renewal.url_redirect.download_page_url)
      end

      it "falls back past newer purchases for another buyer or product" do
        eligible_renewal = create_renewal(succeeded_at: 3.days.ago, email: "updated@example.com").tap(&:create_url_redirect!)
        create_renewal(succeeded_at: 2.days.ago, purchaser: create(:user)).tap(&:create_url_redirect!)
        create_renewal(succeeded_at: 1.day.ago, link: create(:membership_product, user: creator)).tap(&:create_url_redirect!)

        expect(results.first[:purchase][:download_url]).to eq(eligible_renewal.url_redirect.download_page_url)
      end

      it "does not link a transferred card to a renewal left on the previous owner" do
        previous_owner = create(:user)
        purchase.subscription.update!(user: previous_owner)
        create_renewal(purchaser: previous_owner, email: previous_owner.email).tap(&:create_url_redirect!)

        # UrlRedirectsController#check_permissions authorizes against the rendered purchase's
        # purchaser, so this renewal's redirect would bounce the viewer to purchaser verification
        # keyed to the previous owner's email. No link beats a link that cannot resolve.
        expect(results.first[:purchase][:id]).to eq(purchase.external_id)
        expect(results.first[:purchase][:download_url]).to be_nil
      end

      it "does not select another user's renewal on the viewer's own subscription" do
        other_user = create(:user)
        create_renewal(purchaser: other_user, email: other_user.email).tap(&:create_url_redirect!)

        expect(results.first[:purchase][:download_url]).to be_nil
      end

      it "ignores unsuccessful renewal attempts" do
        create_renewal(purchase_state: "failed").tap(&:create_url_redirect!)
        create_renewal(purchase_state: "in_progress").tap(&:create_url_redirect!)

        expect(results.first[:purchase][:download_url]).to be_nil
      end

      it "uses the newest renewal deterministically when timestamps match" do
        succeeded_at = 1.day.ago
        create_renewal(succeeded_at:).tap(&:create_url_redirect!)
        newest_renewal = create_renewal(succeeded_at:).tap(&:create_url_redirect!)

        expect(results.first[:purchase][:download_url]).to eq(newest_renewal.url_redirect.download_page_url)
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
          library_props
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
        gift_purchase = results.find { _1[:purchase][:id] == gift_receiver_purchase.external_id }
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

        expect(refunded_gift_purchase).to be_stripe_refunded
        gift_purchase = results.find { _1[:purchase][:id] == refunded_gift_purchase.external_id }
        expect(gift_purchase[:purchase][:download_url]).to eq(renewal.url_redirect.download_page_url)
        expect(gifter.url_redirect).to be_nil
      end
    end

    describe "bundle purchases" do
      let(:purchase1) { create(:purchase, purchaser: buyer, link: create(:product, :bundle)) }
      let(:purchase2) { create(:purchase, purchaser: buyer, link: create(:product, :bundle)) }

      before do
        [purchase1, purchase2].each do |bundle_purchase|
          bundle_purchase.link.bundle_products.each_with_index do |bundle_product, index|
            create(:product_file, link: bundle_product.product, display_name: "#{bundle_purchase.external_id}-file-#{index}")
          end
        end

        purchase1.create_artifacts_and_send_receipt!
        purchase2.create_artifacts_and_send_receipt!
      end

      it "renders member purchases instead of the bundle purchase and lists bundle filter options" do
        props = library_props
        ids = props[:results].map { _1[:purchase][:id] }

        expect(ids).to match_array(
          (purchase1.product_purchases + purchase2.product_purchases).map(&:external_id) + [purchase.external_id]
        )
        expect(ids).not_to include(purchase1.external_id, purchase2.external_id)

        expect(props[:bundles]).to eq(
          [
            { id: purchase2.link.external_id, label: "Bundle" },
            { id: purchase1.link.external_id, label: "Bundle" },
          ]
        )
      end

      it "filters results to the members of the selected bundles" do
        matches = results(bundle_ids: [purchase1.link.external_id])

        expect(matches.map { _1[:purchase][:id] }).to match_array(purchase1.product_purchases.map(&:external_id))
      end

      it "prepares and returns a combined ZIP for the selected bundle purchase" do
        props = library_props(bundle_ids: [purchase1.link.external_id])

        expected_download = { id: purchase1.link.external_id, label: "Bundle", download_url: nil }
        expect(props[:bundle_downloads]).to eq([expected_download])
        archive = purchase1.link.product_files_archives.alive.entity_archives.sole
        expect(archive.product_files.map(&:link_id).sort).to eq(purchase1.product_purchases.map(&:link_id).sort)

        archive.mark_in_progress!
        archive.mark_ready!
        props = library_props(bundle_ids: [purchase1.link.external_id])

        expected_download[:download_url] = url_redirect_download_archive_path(purchase1.url_redirect.token)
        expect(props[:bundle_downloads]).to eq([expected_download])
      end

      it "does not create a combined ZIP when a member product has stampable pdfs" do
        create(:readable_document, pdf_stamp_enabled: true, link: purchase1.product_purchases.first.link)

        props = library_props(bundle_ids: [purchase1.link.external_id])

        expect(props[:bundle_downloads]).to eq([])
        expect(purchase1.link.product_files_archives.alive).to be_empty
      end

      it "queues a replacement ZIP when the matching archive has failed" do
        library_props(bundle_ids: [purchase1.link.external_id])
        archive = purchase1.link.product_files_archives.alive.entity_archives.sole
        archive.mark_failed!

        props = library_props(bundle_ids: [purchase1.link.external_id])

        expected_download = { id: purchase1.link.external_id, label: "Bundle", download_url: nil }
        expect(props[:bundle_downloads]).to eq([expected_download])
        archives = purchase1.link.product_files_archives.alive.entity_archives.order(:id)
        expect(archives.map(&:product_files_archive_state)).to contain_exactly("failed", "queueing")
      end

      it "matches nothing when no selected bundle id resolves to a product" do
        expect(results(bundle_ids: ["garbage"])).to be_empty
      end

      it "keeps a bundle purchase hidden when its member rows land on a later page" do
        create_list(:purchase, 15, purchaser: buyer) # push the bundle members past page 1

        page_ids = (1..2).flat_map { |page| library_props(page: page.to_s)[:results].map { _1[:purchase][:id] } }

        expect(page_ids).to include(*purchase1.product_purchases.map(&:external_id))
        expect(page_ids).not_to include(purchase1.external_id)
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
          props = library_props

          row = props[:results].find { _1[:purchase][:id] == memberless_purchase.external_id }
          expect(row).to be_present
          expect(row[:product][:name]).to eq("Memberless Bundle")
          expect(row[:purchase][:download_url]).to eq(memberless_purchase.url_redirect.download_page_url)

          # Nothing filters to it, so it must not offer itself as a bundle filter option.
          expect(props[:bundles].map { _1[:id] }).to_not include(memberless_bundle.external_id)
        end
      end

      context "when every member purchase is excluded from the library" do
        it "renders the bundle itself so the buyer keeps a row for the purchase" do
          purchase1.product_purchases.each { _1.update!(is_deleted_by_buyer: true) }

          row = results.find { _1[:purchase][:id] == purchase1.external_id }
          expect(row).to be_present
        end
      end
    end
  end

  describe "#receipt_purchases" do
    before do
      purchase.create_url_redirect!
    end

    def receipt_purchases(external_ids)
      described_class.new(buyer).receipt_purchases(external_ids)
    end

    it "returns the receipt data for the buyer's purchases" do
      expect(receipt_purchases([purchase.external_id])).to eq([
                                                                {
                                                                  id: purchase.external_id,
                                                                  email: purchase.email,
                                                                  permalink: product.unique_permalink,
                                                                  has_third_party_analytics: false,
                                                                }
                                                              ])
    end

    it "returns nothing for ids that are not the buyer's purchases" do
      other_purchase = create(:purchase)

      expect(receipt_purchases([other_purchase.external_id])).to eq([])
    end

    it "excludes purchases that are not visible in the library" do
      purchase.update!(is_deleted_by_buyer: true)

      expect(receipt_purchases([purchase.external_id])).to eq([])
    end

    it "excludes membership purchases whose subscription no longer grants access" do
      product.update!(block_access_after_membership_cancellation: true)
      purchase.subscription.update!(cancelled_at: 1.day.ago)

      expect(receipt_purchases([purchase.external_id])).to eq([])
    end

    it "includes a bundle purchase even though its members render in its place" do
      bundle_purchase = create(:purchase, purchaser: buyer, link: create(:product, :bundle))
      bundle_purchase.create_artifacts_and_send_receipt!

      ids = receipt_purchases([bundle_purchase.external_id]).map { _1[:id] }
      expect(ids).to eq([bundle_purchase.external_id])
    end

    describe "has_third_party_analytics" do
      it "detects product-level receipt analytics" do
        create(:third_party_analytic, user: creator, link: product, location: "receipt", analytics_code: "<script>test</script>")

        expect(receipt_purchases([purchase.external_id]).first[:has_third_party_analytics]).to eq(true)
      end

      it "detects product-level analytics with 'all' location" do
        create(:third_party_analytic, user: creator, link: product, location: "all", analytics_code: "<script>test</script>")

        expect(receipt_purchases([purchase.external_id]).first[:has_third_party_analytics]).to eq(true)
      end

      it "detects user-level universal receipt analytics" do
        create(:third_party_analytic, user: creator, link: nil, location: "receipt", analytics_code: "<script>test</script>")

        expect(receipt_purchases([purchase.external_id]).first[:has_third_party_analytics]).to eq(true)
      end

      it "ignores deleted analytics" do
        create(:third_party_analytic, user: creator, link: product, location: "receipt", analytics_code: "<script>test</script>", deleted_at: 1.day.ago)

        expect(receipt_purchases([purchase.external_id]).first[:has_third_party_analytics]).to eq(false)
      end

      it "ignores analytics for non-receipt locations" do
        create(:third_party_analytic, user: creator, link: product, location: "product", analytics_code: "<script>test</script>")

        expect(receipt_purchases([purchase.external_id]).first[:has_third_party_analytics]).to eq(false)
      end
    end
  end
end
