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
        show_archived_only: false,
        subscriptions_only: false
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

    describe "subscriptions filter" do
      let!(:one_off_purchase) do
        create(:purchase, purchaser: buyer, link: create(:product, name: "One-off product")).tap { _1.create_url_redirect! }
      end

      # Checkout makes the purchaser the subscription's owner (Purchase::BaseService#create_subscription);
      # the membership_purchase factory leaves it on a generated user.
      before { purchase.subscription.update!(user: buyer) }

      def subscription_ids(**params)
        results(subscriptions_only: true, **params).map { _1[:purchase][:id] }
      end

      def status_label(card_purchase = purchase)
        results(subscriptions_only: true).find { _1[:purchase][:id] == card_purchase.external_id }.dig(:purchase, :subscription, :status_label)
      end

      def subscription_manage_location(card_purchase = purchase)
        results(subscriptions_only: true).find { _1[:purchase][:id] == card_purchase.external_id }.dig(:purchase, :subscription, :manage_url)
      end

      def buyer_date(time)
        time.in_time_zone(buyer.timezone).to_fs(:formatted_date_abbrev_month)
      end

      def owned_membership(name, **attributes)
        product = create(:membership_product, name:, user: creator)
        create(:membership_purchase, link: product, purchaser: buyer, subscription: create(:subscription, link: product, user: buyer), **attributes)
          .tap(&:create_url_redirect!)
      end

      def renewal(subscription, **attributes)
        create(:membership_purchase, link: subscription.link, subscription:, purchaser: buyer, is_original_subscription_purchase: false, **attributes)
      end

      it "keeps only the memberships and leaves the one-off purchases out" do
        expect(results(subscriptions_only: true).map { _1[:product][:name] }).to eq(["hello"])
      end

      it "drops a membership whose subscription has already ended" do
        purchase.subscription.update!(cancelled_at: 1.day.ago)

        expect(results(subscriptions_only: true)).to be_empty
      end

      it "echoes the flag back to the page so the tab stays selected" do
        expect(library_props(subscriptions_only: true)[:search][:subscriptions_only]).to be(true)
      end

      it "keeps a membership the buyer cancelled that is still inside its paid period" do
        purchase.subscription.update!(cancelled_at: 1.week.from_now)

        expect(subscription_ids).to eq([purchase.external_id])
      end

      it "drops a membership whose last payment failed" do
        purchase.subscription.update!(failed_at: 1.day.ago)

        expect(results(subscriptions_only: true)).to be_empty
      end

      it "drops a fixed-length membership that has ended" do
        purchase.subscription.update!(ended_at: 1.day.ago)

        expect(results(subscriptions_only: true)).to be_empty
      end

      it "keeps a membership whose signup charge was refunded while its subscription is still alive" do
        purchase.update!(stripe_refunded: true)

        expect(subscription_ids).to eq([purchase.external_id])
      end

      it "lists a membership the buyer removed from the library, since removing it does not stop billing" do
        purchase.update!(is_deleted_by_buyer: true)

        expect(subscription_ids).to eq([purchase.external_id])
        expect(results.map { _1[:purchase][:id] }).not_to include(purchase.external_id)
      end

      it "lists archived memberships with the rest and ignores a stale archive filter" do
        purchase.update!(is_archived: true)
        one_off_purchase.update!(is_archived: true)

        expect(subscription_ids).to eq([purchase.external_id])
        props = library_props(subscriptions_only: true, show_archived_only: true)
        expect(props[:results].map { _1[:purchase][:id] }).to eq([purchase.external_id])
        expect(props[:search][:show_archived_only]).to be(false)
      end

      it "counts every ongoing membership as unarchived on this tab, leaving the Purchases counts alone" do
        create(:purchase, purchaser: buyer, is_archived: true)
        owned_membership("Archived membership", is_archived: true)

        subscriptions_props = library_props(subscriptions_only: true)
        expect(subscriptions_props[:archived_count]).to eq(0)
        expect(subscriptions_props[:unarchived_count]).to eq(2)

        purchases_props = library_props
        expect(purchases_props[:archived_count]).to eq(2)
        expect(purchases_props[:unarchived_count]).to eq(2)
      end

      it "reports zero counts when every membership has ended, even though one-off purchases remain" do
        purchase.subscription.update!(ended_at: 1.day.ago)

        props = library_props(subscriptions_only: true)
        expect(props[:archived_count]).to eq(0)
        expect(props[:unarchived_count]).to eq(0)
      end

      it "does not list or count another buyer's memberships" do
        other_buyer = create(:user)
        create(:membership_purchase, link: product, purchaser: other_buyer).tap { _1.subscription.update!(user: other_buyer) }.create_url_redirect!

        props = library_props(subscriptions_only: true)
        expect(props[:results].map { _1[:purchase][:id] }).to eq([purchase.external_id])
        expect(props[:unarchived_count]).to eq(1)
        expect(described_class.new(other_buyer).library_props(subscriptions_only: true)[:results].map { _1[:purchase][:id] })
          .not_to include(purchase.external_id)
      end

      it "leaves out a subscription that another account now owns, even though this buyer still holds the purchase" do
        purchase.subscription.update!(user: create(:user))

        expect(results(subscriptions_only: true)).to be_empty
        expect(results.map { _1[:purchase][:id] }).to include(purchase.external_id)
      end

      it "lists a claimed guest subscription that no account owns yet" do
        purchase.subscription.update!(user: nil)

        expect(subscription_ids).to eq([purchase.external_id])
      end

      it "shows a gifted membership to its recipient and never to the gift sender" do
        gift_product = create(:membership_product, name: "Gifted membership", user: creator)
        gift_subscription = create(:subscription, link: gift_product, user: buyer)
        sender = create(:user)
        sender_purchase = create(:membership_purchase, link: gift_product, subscription: gift_subscription, purchaser: sender, is_gift_sender_purchase: true)
        receiver_purchase = create(:purchase, :gift_receiver, link: gift_product, purchaser: buyer, subscription: gift_subscription, is_original_subscription_purchase: false)
          .tap(&:create_url_redirect!)
        create(:gift, link: gift_product, gifter_purchase: sender_purchase, giftee_purchase: receiver_purchase, gifter_email: sender.email, giftee_email: buyer.email)

        expect(subscription_ids).to include(receiver_purchase.external_id)
        expect(status_label(receiver_purchase)).to eq("Gift · Paid through #{buyer_date(gift_subscription.reload.end_time_of_subscription)}")
        expect(described_class.new(sender).library_props(subscriptions_only: true)[:results]).to be_empty
      end

      it "lists one card per subscription when a plan change left a second original purchase" do
        newer_original = create(:membership_purchase, link: product, purchaser: buyer, subscription: purchase.subscription).tap(&:create_url_redirect!)

        expect(subscription_ids).to eq([newer_original.external_id])
        expect(library_props(subscriptions_only: true)[:unarchived_count]).to eq(1)
        expect(results.map { _1[:purchase][:id] }).to include(purchase.external_id, newer_original.external_id)
      end

      it "searches and pages the whole list, including removed memberships" do
        purchase.update!(is_deleted_by_buyer: true)
        15.times { |i| owned_membership(format("Membership %02d", i + 1)) }

        expect(library_props(subscriptions_only: true)[:pagination]).to include(count: 16, pages: 2)
        expect(results(subscriptions_only: true, page: "2").size).to eq(1)
        expect(subscription_ids(query: "hello")).to eq([purchase.external_id])
      end

      it "links each card to the subscription's own manage page" do
        expect(results(subscriptions_only: true).sole.dig(:purchase, :subscription, :manage_url))
          .to eq("/subscriptions/#{purchase.subscription.external_id}/manage")
      end

      it "adds no subscription details to Purchases cards" do
        expect(results.map { _1[:purchase] }).to all(satisfy { !_1.key?(:subscription) })
      end

      describe "supported ownership flows" do
        def gifted_membership(payer:, payer_email: "payer@example.com", subscription_owner: buyer)
          gift_product = create(:membership_product, name: "Gifted membership", user: creator)
          subscription = create(:subscription, link: gift_product, user: subscription_owner)
          gift = create(:gift, link: gift_product, giftee_email: buyer.email, gifter_email: payer_email)
          gifter = create(:membership_purchase, link: gift_product, subscription:, purchaser: payer, email: payer_email, is_gift_sender_purchase: true, gift_given: gift)
          receiver = create(:membership_purchase, :gift_receiver, link: gift_product, subscription:, purchaser: buyer, email: buyer.email).tap(&:create_url_redirect!)
          gift.update!(giftee_purchase: receiver)
          [gift, gifter, receiver]
        end

        def convert(gift)
          Gift::ConvertToNonGiftService.new(gift:, gifter_signed_off: true, giftee_signed_off: true, reason: "spec").process!
        end

        it "lists a guest checkout once the buyer signs up and it is attached to their account" do
          guest_product = create(:membership_product, name: "Guest membership", user: creator)
          guest = create(:membership_purchase, link: guest_product, purchaser: nil, email: buyer.email, subscription: create(:subscription, link: guest_product, user: nil))
            .tap(&:create_url_redirect!)
          expect(subscription_ids).not_to include(guest.external_id)

          guest.attach_to_user_and_card(buyer, nil, nil)

          expect(guest.subscription.reload.user).to eq(buyer)
          expect(subscription_ids).to include(guest.external_id)
        end

        it "moves a membership to the account it was reassigned to and off the previous one" do
          previous_owner = create(:user, email: "previous-owner@example.com")
          moved_product = create(:membership_product, name: "Moved membership", user: creator)
          moved = create(:membership_purchase, link: moved_product, purchaser: previous_owner, email: previous_owner.email,
                                               subscription: create(:subscription, link: moved_product, user: previous_owner)).tap(&:create_url_redirect!)

          expect(Purchase::ReassignByEmailService.new(from_email: previous_owner.email, to_email: buyer.email).perform).to be_success

          expect(moved.subscription.reload.user).to eq(buyer)
          expect(subscription_ids).to include(moved.external_id)
          expect(described_class.new(previous_owner).library_props(subscriptions_only: true)[:results]).to be_empty
        end

        it "keeps listing a subscription this account still pays for after User#transfer_purchases! moves its purchase away" do
          holder = create(:user, email: "new-holder@example.com")
          purchase.update!(email: buyer.email)

          buyer.transfer_purchases!(new_email: holder.email)

          expect(purchase.reload.purchaser).to eq(holder)
          expect(purchase.subscription.reload.user).to eq(buyer)
          card = results(subscriptions_only: true).sole
          expect(card[:purchase]).to eq(
            id: "subscription:#{purchase.subscription.external_id}",
            is_archived: false,
            download_url: nil,
            variants: "Untitled",
            subscription: {
              status_label: "Renews on #{buyer_date(purchase.subscription.end_time_of_subscription)}",
              manage_label: "Manage membership",
              manage_url: "/subscriptions/#{purchase.subscription.external_id}/manage",
            },
          )
          expect(card.to_json).not_to include(purchase.external_id, purchase.url_redirect.token)
          expect(results.map { _1[:purchase][:id] }).not_to include(purchase.external_id)
        end

        it "gives the new holder of a transferred purchase its access but not the payer's billing card" do
          holder = create(:user, email: "new-holder@example.com")
          purchase.update!(email: buyer.email)

          buyer.transfer_purchases!(new_email: holder.email)

          holder_library = described_class.new(holder)
          expect(holder_library.library_props(subscriptions_only: true)[:results]).to be_empty
          expect(holder_library.library_props[:results].map { _1[:purchase][:id] }).to include(purchase.external_id)
        end

        it "keeps the payer's billing card when a converted gift's receiver row is transferred to the payer after the payer leg moved away" do
          giftee = create(:user, email: "giftee@example.com")
          holder = create(:user, email: "payer-leg-holder@example.com")
          gift_product = create(:membership_product, name: "Gifted membership", user: creator)
          subscription = create(:subscription, link: gift_product, user: giftee)
          gift = create(:gift, link: gift_product, giftee_email: giftee.email, gifter_email: buyer.email)
          gifter = create(:membership_purchase, link: gift_product, subscription:, purchaser: buyer, email: buyer.email, is_gift_sender_purchase: true, gift_given: gift)
          receiver = create(:membership_purchase, :gift_receiver, link: gift_product, subscription:, purchaser: giftee, email: giftee.email).tap(&:create_url_redirect!)
          gift.update!(giftee_purchase: receiver)

          convert(gift)
          buyer.transfer_purchases!(new_email: holder.email)
          giftee.transfer_purchases!(new_email: buyer.email)
          gifter.reload.update!(is_archived: true)

          expect([gifter.purchaser, receiver.reload.purchaser, subscription.reload.user]).to eq([holder, buyer, buyer])
          cards = results(subscriptions_only: true).select { _1[:product][:name] == "Gifted membership" }
          expect(cards.sole[:purchase]).to include(
            id: "subscription:#{subscription.external_id}",
            is_archived: false,
            download_url: nil,
            subscription: include(manage_url: "/subscriptions/#{subscription.external_id}/manage"),
          )
          holder_library = described_class.new(holder)
          expect(holder_library.library_props(subscriptions_only: true)[:results]).to be_empty
          expect(holder_library.library_props(show_archived_only: true)[:results].map { _1[:purchase][:id] }).to eq([gifter.external_id])
        end

        it "keys a billing card apart from a held card whose purchase shares its subscription's database id" do
          holder = create(:user, email: "new-holder@example.com")
          shared_id = [Purchase.maximum(:id).to_i, Subscription.maximum(:id).to_i].max + 1_000
          moved_product = create(:membership_product, name: "Moved membership", user: creator)
          moved_subscription = create(:subscription, id: shared_id, link: moved_product, user: buyer)
          create(:membership_purchase, link: moved_product, purchaser: buyer, email: buyer.email, subscription: moved_subscription)
          held_product = create(:membership_product, name: "Held membership", user: creator)
          held = create(:membership_purchase, id: shared_id, link: held_product, purchaser: buyer, subscription: create(:subscription, link: held_product, user: buyer))
          buyer.transfer_purchases!(new_email: holder.email)
          expect(moved_subscription.external_id).to eq(held.external_id)

          keys = results(subscriptions_only: true).map { _1[:purchase][:id] }

          expect(keys).to eq(keys.uniq)
          expect(keys).to include(held.external_id, "subscription:#{moved_subscription.external_id}")
          expect(results.map { _1[:purchase][:id] }).to include(held.external_id)
        end

        it "lists a converted gift only for the account-backed payer, keeping the recipient's Library access" do
          payer = create(:user, email: "payer@example.com")
          gift, gifter, receiver = gifted_membership(payer:)
          expect(subscription_ids).to include(receiver.external_id)

          convert(gift)

          expect(subscription_ids).not_to include(receiver.external_id)
          expect(results.map { _1[:purchase][:id] }).to include(receiver.external_id)
          payer_cards = described_class.new(payer).library_props(subscriptions_only: true)[:results]
          expect(payer_cards.map { _1[:purchase][:id] }).to eq([gifter.external_id])
          expect(payer_cards.sole.dig(:purchase, :subscription, :manage_url)).to eq("/subscriptions/#{gifter.subscription.external_id}/manage")
        end

        it "drops a gift converted to a guest payer from the recipient's tab, keeping their Library access" do
          gift, _, receiver = gifted_membership(payer: nil)
          expect(subscription_ids).to include(receiver.external_id)

          convert(gift)

          expect(receiver.subscription.reload.user).to be_nil
          expect(subscription_ids).not_to include(receiver.external_id)
          expect(results.map { _1[:purchase][:id] }).to include(receiver.external_id)
        end

        it "keeps a still-gifted membership on the tab of a recipient who had no account when it was given" do
          _, _, receiver = gifted_membership(payer: create(:user), subscription_owner: nil)

          expect(subscription_ids).to include(receiver.external_id)
          expect(status_label(receiver)).to start_with("Gift · Paid through ")
        end
      end

      describe "status labels" do
        it "shows the renewal date of a renewing membership" do
          expect(status_label).to eq("Renews on #{buyer_date(purchase.subscription.end_time_of_subscription)}")
        end

        it "says the subscription ends, not access, after a cancellation on a product that keeps access" do
          purchase.subscription.cancel!(by_seller: false)

          expect(purchase.subscription.reload.cancelled_at).to be_future
          expect(status_label).to eq("Cancelled · Subscription ends on #{buyer_date(purchase.subscription.cancelled_at)}")
        end

        it "says access ends after a cancellation on a product that blocks access once cancelled" do
          product.update!(block_access_after_membership_cancellation: true)
          purchase.subscription.cancel!(by_seller: false)

          expect(status_label).to eq("Cancelled · Access until #{buyer_date(purchase.subscription.reload.cancelled_at)}")
        end

        it "says a cancelled free trial ends without implying it was paid for" do
          trial_purchase = create(:free_trial_membership_purchase, purchaser: buyer, link: create(:membership_product, :with_free_trial_enabled, name: "Trial membership", user: creator))
            .tap(&:create_url_redirect!)
          trial_purchase.subscription.cancel!(by_seller: false)

          expect(trial_purchase.subscription.reload.cancelled_at).to eq(trial_purchase.subscription.free_trial_ends_at)
          expect(status_label(trial_purchase)).to eq("Cancelled · Subscription ends on #{buyer_date(trial_purchase.subscription.free_trial_ends_at)}")
        end

        it "says a seller-cancelled installment plan takes no further payments, since its access already ended" do
          installment = create(:installment_plan_purchase, purchaser: buyer, link: create(:product, :with_installment_plan, name: "Course", user: creator))
            .tap(&:create_url_redirect!)
          installment.subscription.cancel!(by_seller: true)

          expect(installment.subscription.reload).to be_pending_cancellation
          expect(installment.subscription.grant_access_to_product?).to be(false)
          expect(status_label(installment)).to eq("Installment plan · Cancelled · No further payments")
        end

        it "flags a failed renewal that is still being retried" do
          # Subscription#pending_failure? reads the newest purchase by created_at, so keep the order unambiguous.
          travel(1.minute) { renewal(purchase.subscription, purchase_state: "failed") }

          expect(status_label).to eq("Payment failed")
        end

        it "shows the first charge date during a free trial" do
          trial_purchase = create(:free_trial_membership_purchase, purchaser: buyer, link: create(:membership_product, :with_free_trial_enabled, name: "Trial membership", user: creator))
            .tap(&:create_url_redirect!)

          expect(status_label(trial_purchase)).to eq("Free trial · First charge on #{buyer_date(trial_purchase.subscription.free_trial_ends_at)}")
        end

        it "shows an end date, never a renewal, once a fixed-length membership has collected every charge" do
          purchase.subscription.update!(charge_occurrence_count: 1)

          expect(status_label).to eq("Ends on #{buyer_date(purchase.subscription.end_time_of_subscription)}")
        end

        it "calls out the final charge of a fixed-length membership" do
          purchase.subscription.update!(charge_occurrence_count: 2)

          expect(status_label).to eq("Final charge on #{buyer_date(purchase.subscription.end_time_of_subscription)}")
        end

        it "shows installment progress and the next payment date" do
          installment = create(:installment_plan_purchase, purchaser: buyer, link: create(:product, :with_installment_plan, name: "Course", user: creator))
            .tap(&:create_url_redirect!)

          expect(status_label(installment)).to eq("Installment plan · 1 of 3 paid · Next payment on #{buyer_date(installment.subscription.end_time_of_subscription)}")
        end

        it "calls out the final installment and then shows the plan as paid in full" do
          installment = create(:installment_plan_purchase, purchaser: buyer, link: create(:product, :with_installment_plan, name: "Course", user: creator))
            .tap(&:create_url_redirect!)
          renewal(installment.subscription, is_installment_payment: true)

          expect(status_label(installment)).to eq("Installment plan · 2 of 3 paid · Final payment on #{buyer_date(installment.subscription.end_time_of_subscription)}")
          expect(subscription_manage_location(installment)).to eq("/subscriptions/#{installment.subscription.external_id}/manage")

          renewal(installment.subscription, is_installment_payment: true)
          expect(status_label(installment)).to eq("Installment plan · Paid in full")
          # SubscriptionsController#manage 404s a paid-off installment plan.
          expect(subscription_manage_location(installment)).to be_nil
        end
      end

      describe "charged-back installments" do
        let(:plan) do
          create(:installment_plan_purchase, purchaser: buyer, email: buyer.email, stripe_transaction_id: "ch_plan_original",
                                             link: create(:product, :with_installment_plan, name: "Course", user: creator)).tap(&:create_url_redirect!)
        end
        let!(:second_installment) { renewal(plan.subscription, is_installment_payment: true, email: buyer.email, stripe_transaction_id: "ch_plan_second") }

        before do
          allow(DisputeEvidence::GenerateReceiptImageService).to receive(:perform)
            .and_return(File.read(Rails.root.join("spec", "support", "fixtures", "test-small.jpg")))
        end

        def dispute!(charge) = Purchase.handle_charge_event(build(:charge_event_dispute_formalized, charge_id: charge.stripe_transaction_id))

        def plan_card(user = buyer)
          described_class.new(user).library_props(subscriptions_only: true)[:results].find { _1[:product][:name] == "Course" }
        end

        it "keeps listing a plan the charge worker still bills after its original payment is charged back" do
          dispute!(plan)

          expect(plan.reload.chargedback_not_reversed?).to be(true)
          expect(plan.subscription.reload.all_charges_disputed?).to be(false)
          expect(plan_card).to include(purchase: include(
            id: "subscription:#{plan.subscription.external_id}",
            is_archived: false,
            download_url: nil,
            subscription: {
              status_label: "Installment plan · 1 payment remaining · Final payment on #{buyer_date(plan.subscription.end_time_of_subscription)}",
              manage_label: "Manage installment plan",
              manage_url: "/subscriptions/#{plan.subscription.external_id}/manage",
            },
          ))
          expect(plan_card.to_json).not_to include(plan.url_redirect.token)
          expect(results.map { _1[:purchase][:id] }).not_to include(plan.external_id)
        end

        it "keeps the billing card with the payer, and gives the new holder none, after the purchases move away" do
          dispute!(plan)
          holder = create(:user, email: "plan-holder@example.com")

          buyer.transfer_purchases!(new_email: holder.email)

          expect(plan.reload.purchaser).to eq(holder)
          expect(plan_card).to include(purchase: include(id: "subscription:#{plan.subscription.external_id}", download_url: nil))
          expect(plan_card(holder)).to be_nil
          expect(described_class.new(holder).library_props[:results]).to be_empty
        end

        it "lists a claimed guest checkout's plan from the buyer's own charge rows" do
          plan.subscription.update!(user: nil)
          dispute!(plan)

          expect(plan_card).to include(purchase: include(id: "subscription:#{plan.subscription.external_id}", download_url: nil))
        end

        it "says no payments remain, not paid in full, once a plan with a charged-back payment has collected every installment" do
          dispute!(plan)
          renewal(plan.subscription, is_installment_payment: true, email: buyer.email)

          expect(plan.subscription.reload.charges_completed?).to be(true)
          expect(plan_card).to include(purchase: include(subscription: { status_label: "Installment plan · No payments remaining", manage_label: "Manage installment plan", manage_url: nil }))
        end

        it "counts a payment as paid again once its chargeback is reversed" do
          dispute!(plan)
          Purchase.handle_charge_event(build(:charge_event_dispute_won, charge_id: plan.stripe_transaction_id))

          expect(plan.reload.chargeback_reversed?).to be(true)
          expect(plan_card).to include(purchase: include(subscription: include(
            status_label: "Installment plan · 2 of 3 paid · Final payment on #{buyer_date(plan.subscription.reload.end_time_of_subscription)}",
          )))
        end

        it "describes the remaining payments when an installment was fully refunded" do
          second_installment.update!(stripe_refunded: true)

          expect(second_installment.reload.chargedback_not_reversed_or_refunded?).to be(true)
          expect(plan_card).to include(purchase: include(subscription: include(
            status_label: "Installment plan · 1 payment remaining · Final payment on #{buyer_date(plan.subscription.reload.end_time_of_subscription)}",
          )))
        end

        it "leaves out a plan with every installment charged back, which the charge worker no longer bills" do
          dispute!(plan)
          dispute!(second_installment)

          expect(plan.subscription.reload.all_charges_disputed?).to be(true)
          expect(plan_card).to be_nil
        end
      end

      describe "label facts" do
        def mixed_subscriptions(group)
          renewing = owned_membership("Renewing #{group}")
          cancelled = owned_membership("Cancelled #{group}").tap { _1.subscription.cancel!(by_seller: false) }
          installments = create(:installment_plan_purchase, purchaser: buyer, link: create(:product, :with_installment_plan, name: "Installments #{group}", user: creator))
          paid_off = create(:installment_plan_purchase, purchaser: buyer, link: create(:product, :with_installment_plan, name: "Paid off #{group}", user: creator))
          2.times { renewal(paid_off.subscription, is_installment_payment: true) }
          trial = create(:free_trial_membership_purchase, purchaser: buyer, link: create(:membership_product, :with_free_trial_enabled, name: "Trial #{group}", user: creator))
          trial.subscription.update!(user: buyer)
          failing = owned_membership("Failing #{group}")
          travel(1.minute) { renewal(failing.subscription, purchase_state: "failed") }
          gift_subscription = gifted_subscription("Gift #{group}")
          [renewing, cancelled, installments, paid_off, trial, failing].map(&:subscription) + [gift_subscription]
        end

        def gifted_subscription(name)
          gift_product = create(:membership_product, name:, user: creator)
          subscription = create(:subscription, link: gift_product, user: buyer)
          gift = create(:gift, link: gift_product, giftee_email: buyer.email, gifter_email: "payer@example.com")
          create(:membership_purchase, link: gift_product, subscription:, email: "payer@example.com", is_gift_sender_purchase: true, gift_given: gift)
          gift.update!(giftee_purchase: create(:membership_purchase, :gift_receiver, link: gift_product, subscription:, purchaser: buyer, email: buyer.email))
          subscription
        end

        def queries_for_subscriptions_tab
          count = 0
          counter = ->(*, payload) { count += 1 unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name]) }
          ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { results(subscriptions_only: true) }
          count
        end

        def charged_back_plan(name)
          plan = create(:installment_plan_purchase, purchaser: buyer, link: create(:product, :with_installment_plan, name:, user: creator))
          plan.update!(chargeback_date: Time.current)
          renewal(plan.subscription, is_installment_payment: true)
          plan
        end

        def queries_for(**params)
          count = 0
          counter = ->(*, payload) { count += 1 unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name]) }
          ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { results(subscriptions_only: true, **params) }
          count
        end

        it "checks charged-back plans for a dispute pause in a fixed number of queries, before search narrows the page" do
          plans = Array.new(3) { charged_back_plan("Charged-back plan #{_1}") }
          three_plans = queries_for(query: "hello")
          plans += Array.new(10) { charged_back_plan("Charged-back plan #{_1 + 3}") }

          expect(results(subscriptions_only: true, query: "hello").map { _1[:purchase][:id] }).to eq([purchase.external_id])
          expect(queries_for(query: "hello") - three_plans).to be <= 2
          expect(results(subscriptions_only: true).map { _1[:purchase][:id] })
            .to match_array([purchase.external_id] + plans.map { "subscription:#{_1.subscription.external_id}" })
        end

        it "pauses exactly the plans Subscription#all_charges_disputed? pauses" do
          disputed = ->(charge) { charge.update!(chargeback_date: Time.current) }
          all_disputed = charged_back_plan("All disputed").tap { disputed.(_1.subscription.purchases.last) }
          partly_disputed = charged_back_plan("Partly disputed")
          reversed = charged_back_plan("Reversed").tap { _1.subscription.purchases.each { |charge| charge.update!(chargeback_date: Time.current, chargeback_reversed: true) } }
          refunded = create(:installment_plan_purchase, purchaser: buyer, link: create(:product, :with_installment_plan, name: "Refunded", user: creator)).tap { _1.update!(stripe_refunded: true) }
          no_success = create(:installment_plan_purchase, purchaser: buyer, link: create(:product, :with_installment_plan, name: "No success", user: creator)).tap { _1.update_columns(purchase_state: "failed") }
          failed_after = charged_back_plan("Failed after disputes").tap do
            disputed.(_1.subscription.purchases.last)
            renewal(_1.subscription, is_installment_payment: true, purchase_state: "failed")
          end
          test_plan = charged_back_plan("Test plan").tap do
            _1.subscription.update!(is_test_subscription: true)
            _1.subscription.purchases.each { |charge| charge.update!(purchase_state: "test_successful", chargeback_date: Time.current) }
          end
          test_plan_live_charges = charged_back_plan("Test plan, live charges").tap do
            _1.subscription.update!(is_test_subscription: true)
            disputed.(_1.subscription.purchases.last)
          end
          membership = owned_membership("Disputed membership").tap { disputed.(_1) }
          subscriptions = [all_disputed, partly_disputed, reversed, refunded, no_success, failed_after, test_plan, test_plan_live_charges, membership].map { _1.subscription.reload }

          expect(described_class.new(buyer).send(:paused_installment_plan_ids, subscriptions.map(&:id)))
            .to match_array(subscriptions.filter_map { _1.id if _1.all_charges_disputed? })
          expect(subscriptions.select(&:all_charges_disputed?)).to contain_exactly(all_disputed.subscription, failed_after.subscription, test_plan.subscription)
        end

        it "keeps the Subscriptions tab at a fixed number of queries as cards are added" do
          mixed_subscriptions(1)
          seven_more = queries_for_subscriptions_tab
          mixed_subscriptions(2)

          expect(results(subscriptions_only: true).size).to eq(15)
          expect(queries_for_subscriptions_tab - seven_more).to be <= 2
        end

        it "match the Subscription methods they stand in for across subscription states" do
          subscriptions = mixed_subscriptions(1)
          refunded = owned_membership("Refunded renewal").subscription
          renewal(refunded, succeeded_at: 1.minute.from_now, stripe_refunded: true)
          reversed = owned_membership("Reversed chargeback").subscription
          renewal(reversed, succeeded_at: 1.minute.from_now, chargeback_date: Time.current, chargeback_reversed: true)
          disputed = create(:installment_plan_purchase, purchaser: buyer, link: create(:product, :with_installment_plan, name: "Disputed original", user: creator))
          disputed.update!(chargeback_date: Time.current)
          renewal(disputed.subscription, is_installment_payment: true)
          unsettled = owned_membership("Unsettled renewal").subscription
          renewal(unsettled, succeeded_at: nil)
          test_subscription = owned_membership("Test", purchase_state: "test_successful").subscription.tap { _1.update!(is_test_subscription: true) }
          facts_class = described_class.const_get(:LabelFacts)

          freeze_time do
            (subscriptions + [refunded, reversed, disputed.subscription, unsettled, test_subscription]).each do |subscription|
              subscription.reload
              facts = facts_class.new(subscription, subscription.purchases.sort_by(&:id))
              expect([facts.charges_completed?, facts.remaining_charges_count, facts.end_time_of_subscription])
                .to eq([subscription.charges_completed?, subscription.remaining_charges_count, subscription.end_time_of_subscription]), subscription.link.name
            end
          end
        end
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

      it "omits a bundle filter option when the bundle product row is gone" do
        surviving = { id: purchase2.link.external_id, label: purchase2.link.name }
        purchase1.update_column(:link_id, Link.maximum(:id).to_i + 1)

        expect { library_props }.not_to raise_error
        expect(library_props[:bundles]).to eq([surviving])
      end

      it "omits bundle downloads for a selected bundle whose product row is gone" do
        missing_bundle_link_id = Link.maximum(:id).to_i + 1
        missing_bundle_external_id = Link.to_external_id(missing_bundle_link_id)
        purchase1.update_column(:link_id, missing_bundle_link_id)

        props = nil
        expect { props = library_props(bundle_ids: [missing_bundle_external_id]) }.not_to raise_error
        expect(props[:results].map { _1[:purchase][:id] }).to match_array(purchase1.product_purchases.map(&:external_id))
        expect(props[:bundle_downloads]).to eq([])
      end

      it "filters results to the members of the selected bundles" do
        matches = results(bundle_ids: [purchase1.link.external_id])

        expect(matches.map { _1[:purchase][:id] }).to match_array(purchase1.product_purchases.map(&:external_id))
      end

      it "ignores bundle filters on the Subscriptions tab, where no membership can be a bundle member" do
        purchase.subscription.update!(user: buyer)
        props = library_props(subscriptions_only: true, bundle_ids: [purchase1.link.external_id])

        expect(props[:results].map { _1[:purchase][:id] }).to eq([purchase.external_id])
        expect(props[:bundles]).to eq([])
        expect(props[:bundle_downloads]).to eq([])
        expect(props[:search][:bundles]).to eq([])
      end

      it "prepares and returns a combined ZIP for the selected bundle purchase" do
        props = library_props(bundle_ids: [purchase1.link.external_id])

        expected_download = { id: purchase1.link.external_id, label: "Bundle", download_url: nil, zip_unavailable_reason: nil, omits_granted_files: false }
        expect(props[:bundle_downloads]).to eq([expected_download])
        archive = purchase1.link.product_files_archives.alive.entity_archives.sole
        expect(archive.product_files.map(&:link_id).sort).to eq(purchase1.product_purchases.map(&:link_id).sort)

        archive.mark_in_progress!
        archive.mark_ready!
        props = library_props(bundle_ids: [purchase1.link.external_id])

        expected_download[:download_url] = url_redirect_download_archive_path(purchase1.url_redirect.token)
        expect(props[:bundle_downloads]).to eq([expected_download])
      end

      it "prepares the combined ZIP with the bundle's own files as well as the members'" do
        own_file = create(:product_file, link: purchase1.link, display_name: "bundle-own")

        props = library_props(bundle_ids: [purchase1.link.external_id])

        expect(props[:bundle_downloads]).to eq([{ id: purchase1.link.external_id, label: "Bundle", download_url: nil, zip_unavailable_reason: nil, omits_granted_files: false }])
        archive = purchase1.link.product_files_archives.alive.entity_archives.sole
        expect(archive.product_files.map(&:id)).to include(own_file.id)
        expect(archive.product_files.map(&:link_id)).to include(*purchase1.product_purchases.map(&:link_id))
      end

      it "keeps a bundle archive scoped to the selected purchase" do
        removed_bundle_product = purchase1.link.bundle_products.first
        removed_bundle_product.mark_deleted!
        new_bundle_product = create(:bundle_product, bundle: purchase1.link)
        create(:product_file, link: new_bundle_product.product, display_name: "repeat-purchase-file")
        repeat_purchase = create(:purchase, purchaser: buyer, link: purchase1.link)
        repeat_purchase.create_artifacts_and_send_receipt!

        library_props(bundle_ids: [purchase1.link.external_id])

        archive = purchase1.link.product_files_archives.alive.entity_archives.sole
        archived_link_ids = archive.product_files.map(&:link_id)
        expect(archived_link_ids).to include(new_bundle_product.product_id)
        expect(archived_link_ids).not_to include(removed_bundle_product.product_id)
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

        expected_download = { id: purchase1.link.external_id, label: "Bundle", download_url: nil, zip_unavailable_reason: nil, omits_granted_files: false }
        expect(props[:bundle_downloads]).to eq([expected_download])
        archives = purchase1.link.product_files_archives.alive.entity_archives.order(:id)
        expect(archives.map(&:product_files_archive_state)).to contain_exactly("failed", "queueing")
      end

      it "stops automatically retrying after a replacement ZIP also failed" do
        library_props(bundle_ids: [purchase1.link.external_id])
        archive = purchase1.link.product_files_archives.alive.entity_archives.sole
        archive.mark_failed!
        library_props(bundle_ids: [purchase1.link.external_id])
        replacement_archive = purchase1.link.product_files_archives.alive.entity_archives.where.not(id: archive.id).sole
        replacement_archive.mark_failed!

        props = library_props(bundle_ids: [purchase1.link.external_id])

        expected_download = { id: purchase1.link.external_id, label: "Bundle", download_url: nil, zip_unavailable_reason: "failed", omits_granted_files: false }
        expect(props[:bundle_downloads]).to eq([expected_download])
        archives = purchase1.link.product_files_archives.alive.entity_archives.order(:id)
        expect(archives.map(&:product_files_archive_state)).to eq(["failed", "failed"])
      end

      it "keeps the bundle row with a too-large reason instead of dropping it" do
        library_props(bundle_ids: [purchase1.link.external_id])
        archive = purchase1.link.product_files_archives.alive.entity_archives.sole
        archive.mark_too_large!

        props = library_props(bundle_ids: [purchase1.link.external_id])

        expected_download = { id: purchase1.link.external_id, label: "Bundle", download_url: nil, zip_unavailable_reason: "too_large", omits_granted_files: false }
        expect(props[:bundle_downloads]).to eq([expected_download])
        expect(purchase1.link.product_files_archives.alive.entity_archives.map(&:product_files_archive_state)).to eq(["too_large"])
      end

      it "names the latest attempt's reason when a failure follows an older too-large archive" do
        library_props(bundle_ids: [purchase1.link.external_id])
        archive = purchase1.link.product_files_archives.alive.entity_archives.sole
        archive.mark_too_large!
        archive.update_columns(updated_at: 8.days.ago)
        bundle_files = purchase1.url_redirect.bundle_archive_product_files
        2.times { purchase1.url_redirect.product_files_archives.create!(product_files: bundle_files).mark_failed! }

        props = library_props(bundle_ids: [purchase1.link.external_id])

        expected_download = { id: purchase1.link.external_id, label: "Bundle", download_url: nil, zip_unavailable_reason: "failed", omits_granted_files: false }
        expect(props[:bundle_downloads]).to eq([expected_download])
      end

      it "allows another retry when the previous bundle ZIP failures are stale" do
        library_props(bundle_ids: [purchase1.link.external_id])
        archive = purchase1.link.product_files_archives.alive.entity_archives.sole
        archive.mark_failed!
        library_props(bundle_ids: [purchase1.link.external_id])
        replacement_archive = purchase1.link.product_files_archives.alive.entity_archives.where.not(id: archive.id).sole
        replacement_archive.mark_failed!
        [archive, replacement_archive].each { _1.update_columns(updated_at: 25.hours.ago) }

        props = library_props(bundle_ids: [purchase1.link.external_id])

        expected_download = { id: purchase1.link.external_id, label: "Bundle", download_url: nil, zip_unavailable_reason: nil, omits_granted_files: false }
        expect(props[:bundle_downloads]).to eq([expected_download])
        archives = purchase1.link.product_files_archives.alive.entity_archives.order(:id)
        expect(archives.map(&:product_files_archive_state)).to eq(["failed", "failed", "queueing"])
      end

      it "stops retrying after the stale-failure recovery attempt also fails" do
        library_props(bundle_ids: [purchase1.link.external_id])
        archive = purchase1.link.product_files_archives.alive.entity_archives.sole
        archive.mark_failed!
        library_props(bundle_ids: [purchase1.link.external_id])
        replacement_archive = purchase1.link.product_files_archives.alive.entity_archives.where.not(id: archive.id).sole
        replacement_archive.mark_failed!
        [archive, replacement_archive].each { _1.update_columns(updated_at: 25.hours.ago) }
        library_props(bundle_ids: [purchase1.link.external_id])
        stale_failure_recovery_archive = purchase1.link.product_files_archives.alive.entity_archives.where(product_files_archive_state: "queueing").sole
        stale_failure_recovery_archive.mark_failed!
        [archive, replacement_archive, stale_failure_recovery_archive].each { _1.update_columns(updated_at: 25.hours.ago) }

        props = library_props(bundle_ids: [purchase1.link.external_id])

        expected_download = { id: purchase1.link.external_id, label: "Bundle", download_url: nil, zip_unavailable_reason: "failed", omits_granted_files: false }
        expect(props[:bundle_downloads]).to eq([expected_download])
        archives = purchase1.link.product_files_archives.alive.entity_archives.order(:id)
        expect(archives.map(&:product_files_archive_state)).to eq(["failed", "failed", "failed"])
      end

      it "queues a fresh ZIP when the matching bundle files keep the same ids but change paths" do
        library_props(bundle_ids: [purchase1.link.external_id])
        archive = purchase1.link.product_files_archives.alive.entity_archives.sole
        archive.mark_in_progress!
        archive.mark_ready!
        product_file = purchase1.product_purchases.first.link.product_files.alive.sole
        product_file.update!(display_name: "renamed-member-file")

        props = library_props(bundle_ids: [purchase1.link.external_id])

        expected_download = { id: purchase1.link.external_id, label: "Bundle", download_url: nil, zip_unavailable_reason: nil, omits_granted_files: false }
        expect(props[:bundle_downloads]).to eq([expected_download])
        archives = purchase1.link.product_files_archives.alive.entity_archives.order(:id)
        expect(archives.map(&:product_files_archive_state)).to eq(["ready", "queueing"])
      end

      it "queues a fresh ZIP when a member product rename changes a bundle archive path" do
        library_props(bundle_ids: [purchase1.link.external_id])
        archive = purchase1.link.product_files_archives.alive.entity_archives.sole
        archive.mark_in_progress!
        archive.mark_ready!
        purchase1.product_purchases.first.link.update!(name: "Renamed member product")

        props = library_props(bundle_ids: [purchase1.link.external_id])

        expected_download = { id: purchase1.link.external_id, label: "Bundle", download_url: nil, zip_unavailable_reason: nil, omits_granted_files: false }
        expect(props[:bundle_downloads]).to eq([expected_download])
        archives = purchase1.link.product_files_archives.alive.entity_archives.order(:id)
        expect(archives.map(&:product_files_archive_state)).to eq(["ready", "queueing"])
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

      # The shared bundle ZIP leaves out stream-only files, including one support granted to this buyer.
      context "when this buyer was granted a stream-only member file" do
        let(:member) { purchase1.product_purchases.first }
        let(:granted_file) { create(:readable_document, link: member.link, stream_only: true) }
        let(:ready_download) { { id: purchase1.link.external_id, label: "Bundle", download_url: url_redirect_download_archive_path(purchase1.url_redirect.token), zip_unavailable_reason: nil, omits_granted_files: false } }

        before do
          granted_file
          library_props(bundle_ids: [purchase1.link.external_id])
          archive = purchase1.link.product_files_archives.alive.entity_archives.sole
          archive.mark_in_progress!
          archive.mark_ready!
        end

        it "keeps the bundle ZIP and flags the file it leaves out" do
          create(:product_file_download_grant, url_redirect: member.url_redirect, product_file: granted_file)

          expect(library_props(bundle_ids: [purchase1.link.external_id])[:bundle_downloads]).to eq(
            [ready_download.merge(omits_granted_files: true)]
          )
        end

        it "flags the granted file when its member product has no other files" do
          member.link.product_files.alive.where.not(id: granted_file.id).each(&:mark_deleted!)
          create(:product_file_download_grant, url_redirect: member.url_redirect, product_file: granted_file)

          expect(library_props(bundle_ids: [purchase1.link.external_id])[:bundle_downloads].sole).to include(
            zip_unavailable_reason: nil, omits_granted_files: true
          )
        end

        it "keeps the ZIP when the stream-only file was not granted" do
          expect(library_props(bundle_ids: [purchase1.link.external_id])[:bundle_downloads]).to eq([ready_download])
        end

        it "keeps the ZIP when another buyer of the same bundle was granted the file" do
          other_purchase = create(:purchase, purchaser: create(:user), link: purchase1.link)
          other_purchase.create_artifacts_and_send_receipt!
          other_member = other_purchase.product_purchases.find_by!(link: member.link)
          create(:product_file_download_grant, url_redirect: other_member.url_redirect, product_file: granted_file)

          expect(library_props(bundle_ids: [purchase1.link.external_id])[:bundle_downloads]).to eq([ready_download])
        end

        it "keeps the ZIP once the granted file is deleted" do
          create(:product_file_download_grant, url_redirect: member.url_redirect, product_file: granted_file)
          granted_file.mark_deleted!

          expect(library_props(bundle_ids: [purchase1.link.external_id])[:bundle_downloads]).to eq([ready_download])
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
