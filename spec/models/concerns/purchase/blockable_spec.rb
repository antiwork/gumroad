# frozen_string_literal: true

require "spec_helper"

describe Purchase::Blockable do
  let(:product) { create(:product) }
  let(:buyer) { create(:user) }
  let(:purchase) { create(:purchase, link: product, email: "gumbot@gumroad.com", purchaser: buyer) }

  describe "#buyer_blocked?" do
    it "returns false when buyer is not blocked" do
      expect(purchase.buyer_blocked?).to eq(false)
    end

    context "when the purchase's browser is blocked" do
      before do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: purchase.browser_guid)
      end

      it "returns true" do
        expect(purchase.buyer_blocked?).to eq(true)
      end
    end

    context "when the purchase's email is blocked" do
      before do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: purchase.email)
      end

      it "returns true" do
        expect(purchase.buyer_blocked?).to eq(true)
      end
    end

    context "when the purchase's paypal email is blocked" do
      let(:purchase) { create(:purchase, link: product, email: "gumbot@gumroad.com", purchaser: buyer, charge_processor_id: PaypalChargeProcessor.charge_processor_id) }

      before do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: purchase.paypal_email)
      end

      it "returns true" do
        expect(purchase.buyer_blocked?).to eq(true)
      end
    end

    context "when the buyer's email address is blocked" do
      before do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: buyer.email)
      end

      it "returns true" do
        expect(purchase.buyer_blocked?).to eq(true)
      end
    end

    context "when the purchase's ip address is blocked" do
      before do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: purchase.ip_address, expires_in: 1.hour)
      end

      it "returns true" do
        expect(purchase.buyer_blocked?).to eq(true)
      end
    end

    context "when the purchase's payment method is blocked" do
      before do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: purchase.stripe_fingerprint)
      end

      it "returns true" do
        expect(purchase.buyer_blocked?).to eq(true)
      end
    end
  end

  describe "blocking on a fraud-related decline" do
    context "for a decline reporting card misuse" do
      it "blocks the card but leaves the buyer's email usable" do
        purchase = build(:purchase_in_progress,
                         email: "foo@example.com",
                         error_code: PurchaseErrorCode::CARD_DECLINED_FRAUDULENT)

        purchase.mark_failed!

        expect(purchase.blocked_by_charge_processor_fingerprint?).to be true
        expect(purchase.blocked_by_email?).to be false
        expect(purchase.blocked_by_browser_guid?).to be false
        expect(purchase.blocked_by_ip_address?).to be false
      end
    end

    context "for a lost or reissued card decline" do
      it "does not block anything" do
        [PurchaseErrorCode::CARD_DECLINED_LOST_CARD, PurchaseErrorCode::CARD_DECLINED_PICKUP_CARD].each do |error_code|
          purchase = build(:purchase_in_progress, email: "foo@example.com", error_code:)

          expect { purchase.mark_failed! }.not_to change { PlatformBlock.count }
          expect(purchase.buyer_blocked?).to be false
        end
      end
    end

    context "for a non-fraudulent transaction" do
      it "does not block the email" do
        purchase = build(:purchase_in_progress,
                         email: "foo@example.com",
                         error_code: "non_fraud_code")

        purchase.mark_failed!

        expect(purchase.blocked_by_email?).to be false
      end
    end

    context "when the buyer already has a clean payment history" do
      let(:settled_count) { Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY }
      let(:long_ago) { 6.months.ago }
      let(:known_card) { "fingerprint-of-a-card-that-has-paid-before" }
      let(:different_card) { "fingerprint-of-some-other-card" }

      # A renewal charge, which is where the exemption matters most: the email and the account on it
      # were copied from the original purchase by Subscription#build_purchase, not typed into a form.
      def renewal_of(subscription, **attributes)
        build(:purchase_in_progress, link: subscription.link, subscription:, **attributes)
      end

      def a_subscription
        create(:membership_purchase).subscription
      end

      it "does not block them, matching on the card the history was paid with" do
        create_list(:purchase, settled_count, email: "loyal@example.com", purchase_state: "successful",
                                              stripe_fingerprint: known_card, created_at: long_ago)
        purchase = build(:purchase_in_progress,
                         email: "someone-else@example.com",
                         stripe_fingerprint: known_card,
                         error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        expect { purchase.mark_failed! }.not_to change { PlatformBlock.count }
        expect(purchase.buyer_blocked?).to be false
      end

      # The case the exemption exists for (gumroad-private#1480): a long-standing subscriber whose
      # renewals have all settled on the card that just declined.
      it "does not block a renewal paid on a card with its own settled history" do
        create_list(:purchase, settled_count, email: "loyal@example.com", purchase_state: "successful",
                                              stripe_fingerprint: known_card, created_at: long_ago)
        purchase = renewal_of(a_subscription,
                              email: "loyal@example.com",
                              stripe_fingerprint: known_card,
                              error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        expect { purchase.mark_failed! }.not_to change { PlatformBlock.count }
        expect(purchase.buyer_blocked?).to be false
      end

      # A subscription's email and account look trustworthy because our own code copied them onto
      # the renewal — but their source was an unauthenticated checkout, so whoever started the
      # membership chose them. Somebody can open a membership under an established customer's
      # address and then have a later renewal on a different, stolen card inherit that customer's
      # record. Only the card counts, on a renewal too.
      it "still blocks a renewal on a different card, even though its email came from our own records" do
        create_list(:purchase, settled_count, email: "loyal@example.com", purchase_state: "successful",
                                              stripe_fingerprint: known_card, created_at: long_ago)
        purchase = renewal_of(a_subscription,
                              email: "loyal@example.com",
                              stripe_fingerprint: different_card,
                              error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        purchase.mark_failed!

        expect(purchase.blocked_by_charge_processor_fingerprint?).to be true
        expect(purchase.blocked_by_email?).to be false
      end

      it "still blocks a renewal on a different card whose subscriber account has the history" do
        purchaser = create(:user)
        create_list(:purchase, settled_count, purchaser:, email: "old-address@example.com",
                                              purchase_state: "successful", stripe_fingerprint: known_card,
                                              created_at: long_ago)
        purchase = renewal_of(a_subscription,
                              purchaser:,
                              email: "new-address@example.com",
                              stripe_fingerprint: different_card,
                              error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        purchase.mark_failed!

        expect(purchase.blocked_by_charge_processor_fingerprint?).to be true
      end

      # The exemption is what protects an established customer, so it must not be claimable by
      # typing their address into checkout. A guest supplies their own email and we resolve an
      # account from it without proving ownership, so email alone can never grant the exemption.
      it "still blocks the card when an unverified guest merely types an established buyer's email" do
        established_buyer = create(:user, email: "loyal@example.com")
        create_list(:purchase, settled_count, purchaser: established_buyer, email: "loyal@example.com",
                                              purchase_state: "successful", stripe_fingerprint: known_card,
                                              created_at: long_ago)
        purchase = build(:purchase_in_progress,
                         purchaser: established_buyer,
                         email: "loyal@example.com",
                         stripe_fingerprint: different_card,
                         error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        purchase.mark_failed!

        expect(purchase.blocked_by_charge_processor_fingerprint?).to be true
        expect(purchase.blocked_by_email?).to be false
      end

      it "still blocks the card when the past purchases were all refunded" do
        create_list(:purchase, settled_count, email: "refunded@example.com", purchase_state: "successful",
                                              stripe_fingerprint: known_card, stripe_refunded: true,
                                              created_at: long_ago)
        purchase = build(:purchase_in_progress,
                         email: "refunded@example.com",
                         stripe_fingerprint: known_card,
                         error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        purchase.mark_failed!

        expect(purchase.blocked_by_charge_processor_fingerprint?).to be true
      end

      it "still blocks the card when the past purchases were free" do
        create_list(:free_purchase, settled_count, email: "freebies@example.com", purchase_state: "successful",
                                                   created_at: long_ago)
        purchase = renewal_of(a_subscription,
                              email: "freebies@example.com",
                              error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        purchase.mark_failed!

        expect(purchase.blocked_by_charge_processor_fingerprint?).to be true
      end

      it "still blocks the card when the past purchases are too recent to have been disputed" do
        create_list(:purchase, settled_count, email: "brand-new@example.com", purchase_state: "successful",
                                              stripe_fingerprint: known_card, created_at: 1.day.ago)
        purchase = build(:purchase_in_progress,
                         email: "brand-new@example.com",
                         stripe_fingerprint: known_card,
                         error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        purchase.mark_failed!

        expect(purchase.blocked_by_charge_processor_fingerprint?).to be true
      end

      # Note: a buyer with a standing chargeback can't reach the decline path at all — the
      # chargeback check in Purchase::Risk fails the purchase first — so the exclusion is
      # asserted directly on the history check.
      it "does not count charged-back purchases as clean history" do
        create_list(:purchase, settled_count, email: "disputed@example.com", purchase_state: "successful",
                                              stripe_fingerprint: known_card, chargeback_date: 1.month.ago,
                                              created_at: long_ago)
        purchase = build(:purchase_in_progress, email: "disputed@example.com", stripe_fingerprint: known_card)

        expect(purchase.buyer_has_clean_payment_history?).to be false
      end

      it "counts a chargeback the buyer won as clean history" do
        create_list(:purchase, settled_count, email: "won-dispute@example.com", purchase_state: "successful",
                                              stripe_fingerprint: known_card, chargeback_date: 1.month.ago,
                                              chargeback_reversed: true, created_at: long_ago)
        purchase = build(:purchase_in_progress, email: "won-dispute@example.com", stripe_fingerprint: known_card)

        expect(purchase.buyer_has_clean_payment_history?).to be true
      end

      it "still blocks the card when the buyer is just short of the threshold" do
        create_list(:purchase, settled_count - 1, email: "newish@example.com",
                                                  purchase_state: "successful",
                                                  stripe_fingerprint: known_card, created_at: long_ago)
        purchase = build(:purchase_in_progress,
                         email: "newish@example.com",
                         stripe_fingerprint: known_card,
                         error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        purchase.mark_failed!

        expect(purchase.blocked_by_charge_processor_fingerprint?).to be true
      end

      # #recent_stripe_fingerprint looks up "the newest card on any purchase sharing this email",
      # and a guest supplies that email themselves. When the failing purchase carries no card of its
      # own there is nothing to hold the lookup down, so it lands on the card of whoever really owns
      # the address — a bystander whose working card we would then block platform-wide. That is the
      # same bug this PR fixes, one method along, so the second block is only taken on a renewal,
      # where our own code copied the email across from the original purchase.
      it "does not block a bystander's card when a guest types their email and the charge carries no card" do
        bystander = create(:user, email: "bystander@example.com")
        create(:purchase, purchaser: bystander, email: "bystander@example.com",
                          purchase_state: "successful", stripe_fingerprint: known_card)
        purchase = build(:purchase_in_progress,
                         email: "bystander@example.com",
                         stripe_fingerprint: nil,
                         error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        purchase.mark_failed!

        expect(PlatformBlock.active.charge_processor_fingerprint.where(object_value: known_card)).to be_empty
      end

      # Same bug one step further in: a renewal's email and account can also be an established
      # buyer's, because whoever started the membership typed that address at an unauthenticated
      # checkout. When the renewal itself carries no card, inferring one from that email or account
      # blocks the established buyer's own working card platform-wide, which is the outcome this
      # whole change exists to prevent.
      it "does not block an established buyer's card when a fingerprint-less renewal fails" do
        established_buyer = create(:user, email: "loyal@example.com")
        create(:purchase, purchaser: established_buyer, email: "loyal@example.com",
                          purchase_state: "successful", stripe_fingerprint: known_card)
        subscription = create(:membership_purchase, purchaser: established_buyer,
                                                    email: "loyal@example.com").subscription
        purchase = renewal_of(subscription,
                              purchaser: established_buyer,
                              email: "loyal@example.com",
                              stripe_fingerprint: nil,
                              error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        purchase.mark_failed!

        expect(PlatformBlock.active.charge_processor_fingerprint.where(object_value: known_card)).to be_empty
      end

      # Built directly rather than through the factory, which reaches out to Stripe to create a real
      # payment method. Only the fingerprint matters in these examples.
      def a_card(fingerprint)
        CreditCard.create!(stripe_fingerprint: fingerprint, visual: "**** **** **** 4242",
                           card_type: CardType::VISA, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                           stripe_customer_id: "cus_test_blockable", expiry_month: 1, expiry_year: 2040)
      end

      # The card that renewal was charged on is still blocked even when the failed charge recorded no
      # fingerprint of its own — but only because the subscription's earlier renewals settled on that
      # same card, which is what proves it belongs to this subscription rather than to whoever the
      # membership was opened under.
      it "blocks the card a renewal was charged on when earlier renewals settled on it too" do
        credit_card = a_card(different_card)
        subscription = a_subscription
        subscription.update!(credit_card:)
        create(:purchase, link: subscription.link, subscription:, credit_card:,
                          price_cents: 5_00, purchase_state: "successful", created_at: long_ago)
        purchase = renewal_of(subscription,
                              credit_card:,
                              stripe_fingerprint: nil,
                              error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        purchase.mark_failed!

        expect(PlatformBlock.active.charge_processor_fingerprint.where(object_value: different_card)).to be_present
      end

      # A renewal can come out at zero — a discount or store credit covering the whole price — and
      # still be recorded as successful with whichever card was on file, without a penny moving to
      # it. That is not the subscription proving the card paid for it, so it grants no provenance:
      # otherwise a membership opened under an established customer's email address could pick up
      # their saved card on one zero-priced renewal and get it blocked platform-wide by a later
      # decline.
      it "does not block a card whose only earlier renewal cost nothing" do
        credit_card = a_card(different_card)
        subscription = a_subscription
        subscription.update!(credit_card:)
        create(:free_purchase, link: subscription.link, subscription:, credit_card:,
                               purchase_state: "successful", created_at: long_ago)
        purchase = renewal_of(subscription,
                              credit_card:,
                              stripe_fingerprint: nil,
                              error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        purchase.mark_failed!

        expect(PlatformBlock.active.charge_processor_fingerprint.where(object_value: different_card)).to be_empty
      end

      # A charge held for Strong Customer Authentication fails up to a quarter of an hour after it
      # was attempted, and the buyer can replace their card in the meantime. Reading the subscription
      # row at failure time would then block the replacement card, which this charge never touched,
      # and leave the card that actually declined alone. The renewal's own credit_card_id is a
      # snapshot of what was charged, so it is read instead.
      it "blocks the card the renewal was charged on, not one attached after the attempt" do
        charged_card = a_card(different_card)
        replacement_card = a_card("fingerprint-of-a-replacement-card")
        subscription = a_subscription
        subscription.update!(credit_card: charged_card)
        create(:purchase, link: subscription.link, subscription:, credit_card: charged_card,
                          price_cents: 5_00, purchase_state: "successful", created_at: long_ago)
        purchase = renewal_of(subscription,
                              credit_card: charged_card,
                              stripe_fingerprint: nil,
                              error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)
        purchase.save!
        subscription.update!(credit_card: replacement_card)

        purchase.mark_failed!

        expect(PlatformBlock.active.charge_processor_fingerprint.where(object_value: different_card)).to be_present
        expect(PlatformBlock.active.charge_processor_fingerprint.where(object_value: "fingerprint-of-a-replacement-card")).to be_empty
      end

      # When the subscription holds no card of its own, both Subscription#build_purchase and
      # Purchase#load_chargeable_for_charging fall back to the card saved on the purchaser's account
      # — and that account can be an established customer's, because the membership could have been
      # opened under their email address at an unauthenticated checkout. So a card that has never
      # settled a charge for this subscription grants no fallback block.
      it "does not block a card that never paid for this subscription" do
        established_buyer = create(:user)
        their_card = a_card(known_card)
        subscription = a_subscription
        subscription.update!(credit_card: their_card)
        purchase = renewal_of(subscription,
                              purchaser: established_buyer,
                              credit_card: their_card,
                              stripe_fingerprint: nil,
                              error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)

        purchase.mark_failed!

        expect(PlatformBlock.active.charge_processor_fingerprint.where(object_value: known_card)).to be_empty
      end
    end
  end

  describe "ip address blocking" do
    context "when purchase's ip address is not blocked" do
      it "returns false for blocked check" do
        expect(purchase.blocked_by_ip_address?).to be false
      end
    end

    context "when purchase's ip address is blocked" do
      before do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: purchase.ip_address, expires_in: 1.hour)
      end

      it "returns true for blocked check" do
        expect(purchase.blocked_by_ip_address?).to be true
        expect(purchase.blocked_by_ip_address_object&.object_value).to eq(purchase.ip_address)
      end
    end
  end

  describe "#block_buyer!" do
    context "when the purchase is made through Stripe" do
      it "blocks buyer's email, browser_guid, ip_address and stripe_fingerprint" do
        purchase.block_buyer!

        [buyer.email, purchase.email, purchase.browser_guid, purchase.ip_address, purchase.stripe_fingerprint].each do |blocked_value|
          expect(PlatformBlock.active.find_by(object_value: blocked_value)).to be_present
        end
      end
    end

    context "when the purchase is made through PayPal" do
      let(:paypal_chargeable) { build(:native_paypal_chargeable) }
      let(:purchase) { create(:purchase, card_visual: paypal_chargeable.visual, purchaser: buyer, chargeable: paypal_chargeable) }

      it "blocks buyer's email, browser_guid, ip_address and card_visual" do
        purchase.block_buyer!

        [buyer.email, purchase.email, purchase.browser_guid, purchase.ip_address, purchase.card_visual].each do |blocked_value|
          expect(PlatformBlock.active.find_by(object_value: blocked_value)).to be_present
        end
      end
    end

    context "when blocking user is provided" do
      let(:admin_user) { create(:admin_user) }

      it "blocks buyer and references the blocker" do
        purchase.block_buyer!(blocking_user_id: admin_user.id)

        [buyer.email, purchase.email, purchase.browser_guid, purchase.ip_address, purchase.stripe_fingerprint].each do |blocked_value|
          blocked_object = PlatformBlock.active.find_by(object_value: blocked_value)
          expect(blocked_object).to be_present
          expect(blocked_object.blocked_by).to eq(admin_user.id)
        end
      end

      it "sets `is_buyer_blocked_by_admin` to true" do
        expect(purchase.is_buyer_blocked_by_admin?).to eq(false)

        purchase.block_buyer!(blocking_user_id: admin_user.id)
        expect(purchase.is_buyer_blocked_by_admin?).to eq(true)
      end
    end

    describe "comments" do
      let(:admin_user) { create(:admin_user) }

      context "when comment content is provided" do
        it "adds buyer blocked comments with the provided content" do
          comment_content = "Blocked by Helper webhook"

          expect do
            purchase.block_buyer!(blocking_user_id: admin_user.id, comment_content:)
          end.to change { purchase.comments.where(content: comment_content, comment_type: "note", author_id: admin_user.id).count }.by(1)
             .and change { purchase.purchaser.comments.where(content: comment_content, comment_type: "note", author_id: admin_user.id, purchase:).count }.by(1)
        end
      end

      context "when comment content is not provided" do
        context "when the blocking user is an admin" do
          it "adds buyer blocked comments with the default content" do
            comment_content = "Buyer blocked by Admin (#{admin_user.email})"

            expect do
              purchase.block_buyer!(blocking_user_id: admin_user.id)
            end.to change { purchase.comments.where(content: comment_content, comment_type: "note", author_id: admin_user.id).count }.by(1)
               .and change { purchase.purchaser.comments.where(content: comment_content, comment_type: "note", author_id: admin_user.id, purchase:).count }.by(1)
          end
        end

        context "when the blocking user is not an admin" do
          it "adds buyer blocked comments with the default content" do
            user = create(:user)
            comment_content = "Buyer blocked by #{user.email}"

            expect do
              purchase.block_buyer!(blocking_user_id: user.id)
            end.to change { purchase.comments.where(content: comment_content, comment_type: "note", author_id: user.id).count }.by(1)
               .and change { purchase.purchaser.comments.where(content: comment_content, comment_type: "note", author_id: user.id, purchase:).count }.by(1)
          end
        end

        context "when the blocking user is not provided" do
          it "adds buyer blocked comments with the default content and GUMROAD_ADMIN as author" do
            comment_content = "Buyer blocked"

            expect do
              purchase.block_buyer!
            end.to change { purchase.comments.where(content: comment_content, comment_type: "note", author_id: GUMROAD_ADMIN_ID).count }.by(1)
               .and change { purchase.purchaser.comments.where(content: comment_content, comment_type: "note", author_id: GUMROAD_ADMIN_ID, purchase:).count }.by(1)
          end
        end
      end
    end
  end

  describe "#unblock_buyer!" do
    context "when buyer is not blocked" do
      it "does not call #unblock! on any blocked objects" do
        expect_any_instance_of(PlatformBlock).to_not receive(:unblock!)
        purchase.unblock_buyer!
      end
    end

    context "when the purchase is made through Stripe" do
      it "unblocks the buyer's email, browser, IP address and stripe_fingerprint" do
        # Block purchase first to create the blocked objects
        purchase.block_buyer!

        purchase.unblock_buyer!
        [buyer.email, purchase.email, purchase.browser_guid, purchase.ip_address, purchase.stripe_fingerprint].each do |blocked_value|
          expect(PlatformBlock.active.find_by(object_value: blocked_value)).to be_nil
        end
      end
    end

    context "when the stripe_fingerprint is nil" do
      it "unblocks the buyer's stripe_fingerprint from a recent purchase" do
        purchase.block_buyer!

        purchase.update_attribute :stripe_fingerprint, nil

        recent_purchase = create(:purchase, purchaser: buyer, email: "gumbot@gumroad.com")

        expect do
          purchase.unblock_buyer!
        end.to change { PlatformBlock.active.find_by(object_value: recent_purchase.stripe_fingerprint) }.from(be_present).to(be_nil)
      end
    end

    context "when the purchase is made through PayPal" do
      let(:paypal_chargeable) { build(:native_paypal_chargeable) }
      let(:purchase) { create(:purchase, card_visual: paypal_chargeable.visual, purchaser: buyer, chargeable: paypal_chargeable) }

      it "unblocks the buyer's email, browser, IP address and card_visual" do
        # Block purchase first to create the blocked objects
        purchase.block_buyer!

        purchase.unblock_buyer!
        [buyer.email, purchase.email, purchase.browser_guid, purchase.ip_address, purchase.card_visual].each do |blocked_value|
          expect(PlatformBlock.active.find_by(object_value: blocked_value)).to be_nil
        end
      end
    end

    it "sets `is_buyer_blocked_by_admin` to false" do
      purchase.block_buyer!
      purchase.update!(is_buyer_blocked_by_admin: true)

      purchase.unblock_buyer!
      expect(purchase.is_buyer_blocked_by_admin).to eq(false)
    end

    context "when the block was written from a different purchase of the same buyer" do
      it "clears a browser_guid block belonging to another purchase" do
        other_purchase = create(:purchase, link: product, email: purchase.email, purchaser: buyer, browser_guid: "other-device-guid")
        other_purchase.block_buyer!

        expect(other_purchase.reload.buyer_blocked?).to eq(true)

        purchase.unblock_buyer!

        expect(PlatformBlock.active.find_by(object_value: "other-device-guid")).to be_nil
        # The sibling row still reads blocked overall: block_buyer! blocked its IP too, and IP
        # blocks deliberately stay row-scoped, so only the browser assertion belongs here.
        expect(other_purchase.reload.blocked_by_browser_guid?).to eq(false)
      end

      it "clears a card fingerprint block belonging to another purchase" do
        other_purchase = create(:purchase, link: product, email: purchase.email, purchaser: buyer, stripe_fingerprint: "other-card-fingerprint")
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: other_purchase.charge_processor_fingerprint)

        purchase.unblock_buyer!

        expect(PlatformBlock.active.find_by(object_value: "other-card-fingerprint")).to be_nil
      end

      it "finds the sibling purchase by email when the acting purchase has no purchaser and a shared card ties the rows together" do
        guest_purchase = create(:purchase, link: product, email: "guest@example.com", purchaser: nil, browser_guid: "guest-acting-guid", stripe_fingerprint: "guest-shared-card")
        sibling = create(:purchase, link: product, email: "guest@example.com", purchaser: nil, browser_guid: "guest-other-guid", stripe_fingerprint: "guest-shared-card")
        sibling.block_buyer!

        guest_purchase.unblock_buyer!

        expect(PlatformBlock.active.find_by(object_value: "guest-other-guid")).to be_nil
      end

      it "leaves alone a guest row that shares nothing but the checkout email, and reports its blocks as surviving" do
        # A card tester checking out under this buyer's address produces exactly this row: same
        # email, no account, its own browser and its own card.
        tester_row = create(:purchase, link: product, email: purchase.email, purchaser: nil,
                                       browser_guid: "tester-guid", stripe_fingerprint: "tester-card")
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "tester-guid")
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "tester-card")

        surviving = purchase.unblock_buyer!

        expect(PlatformBlock.active.find_by(object_value: "tester-guid")).to be_present
        expect(PlatformBlock.active.find_by(object_value: "tester-card")).to be_present
        expect(surviving.map(&:object_value)).to match_array(["tester-guid", "tester-card"])
        expect(tester_row).to be_present
      end

      it "clears a guest row's browser block when a shared card corroborates the email match" do
        guest_row = create(:purchase, link: product, email: purchase.email, purchaser: nil,
                                      browser_guid: "corroborated-guest-guid", stripe_fingerprint: purchase.stripe_fingerprint)
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "corroborated-guest-guid")

        purchase.unblock_buyer!

        expect(PlatformBlock.active.find_by(object_value: "corroborated-guest-guid")).to be_nil
        expect(guest_row).to be_present
      end

      it "does not let a shared browser corroborate a guest row: its own card stays blocked and is reported" do
        # Another person guest-checking-out under the buyer's email on the buyer's machine (a shared
        # household browser) matches on guid, but the card is theirs. A guid names a browser, not a
        # buyer, so it must not pull the row's card into the unblock.
        housemate_row = create(:purchase, link: product, email: purchase.email, purchaser: nil,
                                          browser_guid: purchase.browser_guid, stripe_fingerprint: "housemate-card")
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "housemate-card")

        surviving = purchase.unblock_buyer!

        expect(PlatformBlock.active.find_by(object_value: "housemate-card")).to be_present
        expect(surviving.map(&:object_value)).to include("housemate-card")
        expect(housemate_row).to be_present
      end

      it "does not touch another buyer's blocks" do
        stranger = create(:purchase, link: product, email: "stranger@example.com", browser_guid: "stranger-guid")
        stranger.block_buyer!

        purchase.unblock_buyer!

        expect(PlatformBlock.active.find_by(object_value: "stranger-guid")).to be_present
      end

      it "leaves alone the blocks of a different account that shares the checkout email" do
        former_account_purchase = create(:purchase, link: product, email: purchase.email, purchaser: create(:user),
                                                    browser_guid: "former-account-guid", stripe_fingerprint: "former-account-fingerprint")
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: former_account_purchase.browser_guid)
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: former_account_purchase.stripe_fingerprint)

        purchase.unblock_buyer!

        expect(PlatformBlock.active.find_by(object_value: "former-account-guid")).to be_present
        expect(PlatformBlock.active.find_by(object_value: "former-account-fingerprint")).to be_present
      end

      it "leaves IP blocks on the buyer's other purchases alone" do
        other_purchase = create(:purchase, link: product, email: purchase.email, purchaser: buyer, ip_address: "203.0.113.9")
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: "203.0.113.9", expires_in: 1.day)

        purchase.unblock_buyer!

        expect(PlatformBlock.active.find_by(object_value: "203.0.113.9")).to be_present
        expect(other_purchase).to be_present
      end
    end

    describe "the return value" do
      it "is empty when nothing is left holding the buyer" do
        purchase.block_buyer!

        expect(purchase.unblock_buyer!).to be_empty
      end

      it "reports a block that survives because it is not one of the buyer's own identifiers" do
        purchase.block_buyer!
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: purchase.ip_address, expires_in: 1.day)
        # unblock_by_ip_address! clears the acting row's IP, so re-block it from elsewhere to stand
        # in for a shared-IP block the buyer did not earn.
        allow(purchase).to receive(:unblock_by_ip_address!)

        surviving = purchase.unblock_buyer!

        expect(surviving.map(&:object_value)).to eq([purchase.ip_address])
      end
    end
  end

  describe "#mark_failed" do
    context "when the purchase fails due to a fraud related reason" do
      let(:purchaser) { create(:user, email: "purchaser@example.com") }
      let(:purchase) { create(:purchase, purchaser:, email: "another-email@example.com", purchase_state: "in_progress", stripe_error_code: "card_declined_stolen_card", charge_processor_id: StripeChargeProcessor.charge_processor_id) }

      it "blocks the card only, leaving the buyer able to pay with another one" do
        expect do
          purchase.mark_failed
        end.to change { PlatformBlock.count }.from(0).to(1)
        expect(PlatformBlock.pluck(:object_type, :object_value)).to eq([["charge_processor_fingerprint", purchase.stripe_fingerprint]])
      end
    end

    context "when the purchase fails because the card was reported lost" do
      let(:purchase) { create(:purchase, purchase_state: "in_progress", stripe_error_code: "card_declined_lost_card", charge_processor_id: StripeChargeProcessor.charge_processor_id) }

      it "doesn't block anything, because this is usually a reissued card" do
        expect do
          purchase.mark_failed
        end.to_not change { PlatformBlock.count }
      end
    end

    context "when the purchase fails due to a non-fraud related reason" do
      let(:purchase) { create(:purchase, purchase_state: "in_progress", stripe_error_code: "card_declined_expired_card", charge_processor_id: StripeChargeProcessor.charge_processor_id) }

      it "doesn't block buyer" do
        expect do
          purchase.mark_failed
        end.to_not change { PlatformBlock.count }
      end
    end

    describe "ban card testers" do
      before do
        @purchaser = create(:user, email: "purchaser@example.com")
        Feature.activate(:ban_card_testers)
      end

      context "when previous failed purchases exist with same email or browser_guid but with different cards" do
        context "when previous failed purchases were made within the week" do
          before do
            3.times do |n|
              create(:failed_purchase, purchaser: @purchaser, email: @purchaser.email, stripe_fingerprint: SecureRandom.hex, created_at: n.days.ago)
            end

            @purchase = create(:purchase, purchaser: @purchaser, email: @purchaser.email, purchase_state: "in_progress", stripe_fingerprint: "hij", charge_processor_id: StripeChargeProcessor.charge_processor_id)

            @expected_blocked_objects = [
              ["email", @purchaser.email],
              ["browser_guid", @purchase.browser_guid],
              ["ip_address", @purchase.ip_address],
              ["charge_processor_fingerprint", @purchase.stripe_fingerprint]
            ]
          end

          it "blocks the buyer" do
            expect do
              @purchase.mark_failed!
            end.to change { PlatformBlock.count }.from(0).to(4)
            expect(PlatformBlock.pluck(:object_type, :object_value)).to match_array(@expected_blocked_objects)
          end
        end

        context "when previous failed purchases weren't made within the week" do
          before do
            3.times do |n|
              create(:failed_purchase, purchaser: @purchaser, email: @purchaser.email, stripe_fingerprint: SecureRandom.hex, created_at: (n + 7).days.ago)
            end

            @purchase = create(:purchase, purchaser: @purchaser, email: @purchaser.email, purchase_state: "in_progress", stripe_fingerprint: "hij", charge_processor_id: StripeChargeProcessor.charge_processor_id)
          end

          it "doesn't block buyer" do
            expect do
              @purchase.mark_failed!
            end.to_not change { PlatformBlock.count }
          end
        end
      end

      context "when purchases with different cards fail from the same IP address" do
        context "when failures happen within a day" do
          before do
            3.times do |n|
              create(:failed_purchase, purchaser: @purchaser, ip_address: "192.168.1.1", stripe_fingerprint: SecureRandom.hex, created_at: n.hours.ago)
            end

            @purchase = create(:purchase, purchaser: @purchaser, ip_address: "192.168.1.1", purchase_state: "in_progress", stripe_fingerprint: "hij", charge_processor_id: StripeChargeProcessor.charge_processor_id)
          end

          context "when the ip_address is not already blocked" do
            it "blocks the IP address" do
              travel_to(Time.current) do
                expect do
                  @purchase.mark_failed!
                end.to change { PlatformBlock.count }.from(0).to(1)

                expect(PlatformBlock.pluck(:object_type, :object_value)).to eq [["ip_address", @purchase.ip_address]]
                expect(PlatformBlock.ip_address.active.find_by(object_value: @purchase.ip_address).expires_at.to_i).to eq 7.days.from_now.to_i
              end
            end
          end

          context "when the ip_address is already blocked" do
            it "doesn't overwrite the previous ip_address block" do
              freeze_time do
                expires_in = PlatformBlock::IP_ADDRESS_BLOCKING_DURATION_IN_MONTHS.months

                PlatformBlock.add!(
                  object_type: PlatformBlock::TYPES[:ip_address],
                  object_value: @purchase.ip_address,
                  expires_in:,
                )

                expect do
                  @purchase.mark_failed!
                end.not_to change { PlatformBlock.count }

                expect(PlatformBlock.ip_address.active.find_by(object_value: @purchase.ip_address).expires_at.to_i).to eq expires_in.from_now.to_i
              end
            end
          end
        end

        context "when failures doesn't happen in a day" do
          before do
            3.times do |n|
              create(:failed_purchase, purchaser: @purchaser, ip_address: "192.168.1.1", stripe_fingerprint: SecureRandom.hex, created_at: n.days.ago)
            end
            @purchase = create(:purchase, purchaser: @purchaser, ip_address: "192.168.1.1", purchase_state: "in_progress", stripe_fingerprint: "hij", charge_processor_id: StripeChargeProcessor.charge_processor_id)
          end

          it "doesn't block buyer" do
            expect do
              @purchase.mark_failed!
            end.to_not change { PlatformBlock.count }
          end
        end
      end
    end

    describe "block purchases on product" do
      before do
        Feature.activate(:block_purchases_on_product)
        $redis.set(RedisKey.card_testing_product_watch_minutes, 5)
        $redis.set(RedisKey.card_testing_product_max_failed_purchases_count, 10)
        $redis.set(RedisKey.card_testing_product_block_hours, 1)
        @product = create(:product)
      end

      context "when number of failed purchases exceeds the threshold" do
        before do
          9.times do |n|
            create(:failed_purchase, link: @product)
          end
          @purchase = create(:purchase, link: @product, purchase_state: "in_progress")
        end

        context "when price is not zero" do
          it "blocks purchases on product" do
            travel_to(Time.current) do
              expect do
                @purchase.mark_failed!
              end.to change { PlatformBlock.count }.from(0).to(1)

              expect(PlatformBlock.pluck(:object_type, :object_value)).to eq [["product", @product.id.to_s]]
              expect(PlatformBlock.product.active.find_by(object_value: @product.id).expires_at.to_i).to eq 1.hour.from_now.to_i
            end
          end
        end

        context "when price is zero" do
          before do
            @purchase = create(:purchase, price_cents: 0, link: @product, purchase_state: "in_progress")
          end

          it "doesn't block purchases on product" do
            travel_to(Time.current) do
              expect do
                @purchase.mark_failed!
              end.not_to change { PlatformBlock.count }
            end
          end
        end

        context "when the error code belongs to IGNORED_ERROR_CODES list" do
          before do
            @purchase = create(:purchase, link: @product, purchase_state: "in_progress")
          end

          it "doesn't block purchases on product" do
            travel_to(Time.current) do
              expect do
                @purchase.error_code = PurchaseErrorCode::PERCEIVED_PRICE_CENTS_NOT_MATCHING
                @purchase.mark_failed!
              end.not_to change { PlatformBlock.count }
            end
          end
        end
      end

      context "when number of failed purchases doesn't exceed the threshold" do
        before do
          create(:failed_purchase, link: @product)
          @purchase = create(:purchase, link: @product, purchase_state: "in_progress")
        end

        it "doesn't block purchases on product" do
          travel_to(Time.current) do
            expect do
              @purchase.mark_failed!
            end.not_to change { PlatformBlock.count }
          end
        end
      end

      context "when multiple purchases fail in a row" do
        before do
          $redis.set(RedisKey.card_testing_max_number_of_failed_purchases_in_a_row, 3)
        end

        context "when all recent purchases were failed" do
          before do
            2.times do |n|
              create(:purchase, link: @product, purchase_state: "in_progress").mark_failed!
            end

            @purchase = create(:purchase, link: @product, purchase_state: "in_progress")
          end

          it "blocks purchases on product" do
            travel_to(Time.current) do
              expect do
                @purchase.mark_failed!
              end.to change { PlatformBlock.count }.from(0).to(1)

              expect(PlatformBlock.pluck(:object_type, :object_value)).to eq [["product", @product.id.to_s]]
              expect(PlatformBlock.product.active.find_by(object_value: @product.id).expires_at.to_i).to eq 1.hour.from_now.to_i
            end
          end
        end

        context "when recent purchases fail with an error code from IGNORED_ERROR_CODES list" do
          before do
            2.times do |n|
              create(:purchase, link: @product, purchase_state: "in_progress", error_code: PurchaseErrorCode::PERCEIVED_PRICE_CENTS_NOT_MATCHING).mark_failed!
            end

            @purchase = create(:purchase, link: @product, purchase_state: "in_progress")
          end

          it "doesn't block purchases on product" do
            travel_to(Time.current) do
              expect do
                @purchase.mark_failed!
              end.not_to change { PlatformBlock.count }
            end
          end
        end

        context "when a successful purchase exists in the recent purchases" do
          before do
            create(:purchase, link: @product, purchase_state: "in_progress").mark_failed!
            create(:purchase, link: @product, purchase_state: "in_progress").mark_failed!
            create(:purchase, link: @product, purchase_state: "in_progress").mark_successful!
            @purchase = create(:purchase, link: @product, purchase_state: "in_progress")
          end

          it "doesn't block purchases on product" do
            travel_to(Time.current) do
              expect do
                @purchase.mark_failed!
              end.not_to change { PlatformBlock.count }
            end
          end
        end

        context "when a not_charged purchase exists in the recent purchases" do
          before do
            create(:purchase, link: @product, purchase_state: "in_progress").mark_failed!
            create(:purchase, link: @product, purchase_state: "in_progress").mark_failed!
            create(:purchase, link: @product, purchase_state: "in_progress").mark_not_charged!
            @purchase = create(:purchase, link: @product, purchase_state: "in_progress")
          end

          it "doesn't block purchases on product" do
            freeze_time do
              expect do
                @purchase.mark_failed!
              end.not_to change { PlatformBlock.count }
            end
          end
        end
      end
    end

    describe "flag seller based on recent failures (informational, no payout pause)" do
      let(:seller) { create(:user) }
      let(:product) { create(:product, user: seller) }
      let!(:purchase) { create(:purchase, link: product, purchase_state: "in_progress") }

      before do
        Feature.activate(:block_seller_based_on_recent_failures)
        $redis.set(RedisKey.failed_seller_purchases_watch_minutes, 60)
        $redis.set(RedisKey.max_seller_failed_purchases_price_cents, 1000) # $10
      end

      context "when feature is inactive" do
        before { Feature.deactivate(:block_seller_based_on_recent_failures) }

        it "does not pause payouts for the seller" do
          create_list(:failed_purchase, 5, link: product, price_cents: 250)
          purchase.mark_failed!

          expect(seller.reload.payouts_paused_internally).to be(false)
          expect(seller.payouts_paused_by_source).to be nil
        end
      end

      context "when seller is verified" do
        let(:verified_seller) { create(:user, verified: true) }
        let(:verified_product) { create(:product, user: verified_seller) }
        let!(:verified_purchase) { create(:purchase, link: verified_product, purchase_state: "in_progress") }

        it "does not pause payouts for the seller" do
          create_list(:failed_purchase, 5, link: verified_product, price_cents: 250)
          verified_purchase.mark_failed!

          expect(verified_seller.reload.payouts_paused_internally).to be(false)
          expect(verified_seller.payouts_paused_by_source).to be_nil
        end
      end

      context "when seller is not verified" do
        it "does NOT pause payouts even when threshold is exceeded (informational only)" do
          expect(seller.verified?).to be(false)
          create_list(:failed_purchase, 5, link: product, price_cents: 250)
          purchase.mark_failed!

          expect(seller.reload.payouts_paused_internally).to be(false)
          expect(seller.payouts_paused_by_source).to be_nil
        end

        it "enqueues a #risk notification when threshold is exceeded" do
          create_list(:failed_purchase, 5, link: product, price_cents: 250)

          expect do
            purchase.mark_failed!
          end.to change { InternalNotificationWorker.jobs.size }.by(1)

          job = InternalNotificationWorker.jobs.last
          expect(job["args"][0]).to eq("risk")
          expect(job["args"][2]).to include("failed purchases")
          expect(job["args"][2]).to include("NOT paused")
        end

        it "flags and notifies only once per watch window despite repeated failures" do
          create_list(:failed_purchase, 5, link: product, price_cents: 250)

          expect do
            purchase.mark_failed!
          end.to change { InternalNotificationWorker.jobs.size }.by(1)
             .and change { seller.comments.where(comment_type: Comment::COMMENT_TYPE_ON_PROBATION).count }.by(1)

          # A subsequent failure in the same window must NOT re-fire the comment or the #risk post.
          another_purchase = create(:purchase, link: product, purchase_state: "in_progress")
          expect do
            another_purchase.mark_failed!
          end.to not_change { InternalNotificationWorker.jobs.size }
             .and not_change { seller.comments.where(comment_type: Comment::COMMENT_TYPE_ON_PROBATION).count }
        end
      end

      context "when error code is ignored" do
        it "does not pause payouts for the seller" do
          create_list(:failed_purchase, 5, link: product, price_cents: 250)
          purchase.update!(error_code: PurchaseErrorCode::PERCEIVED_PRICE_CENTS_NOT_MATCHING)
          purchase.mark_failed!

          expect(seller.reload.payouts_paused_internally).to be(false)
          expect(seller.payouts_paused_by_source).to be nil
        end
      end

      context "when seller account is older than 2 years" do
        let(:old_seller) { create(:user, created_at: 3.years.ago) }
        let(:old_product) { create(:product, user: old_seller) }
        let!(:old_purchase) { create(:purchase, link: old_product, purchase_state: "in_progress") }

        it "does not pause payouts for the seller even with high failed amounts" do
          create_list(:failed_purchase, 10, link: old_product, price_cents: 500)
          old_purchase.mark_failed!

          expect(old_seller.reload.payouts_paused_internally).to be(false)
          expect(old_seller.payouts_paused_by_source).to be nil
        end

        it "does not create a comment" do
          create_list(:failed_purchase, 10, link: old_product, price_cents: 500)
          old_purchase.mark_failed!

          expect(old_seller.comments.count).to eq(0)
        end
      end

      context "when seller account is slightly newer than 2 years" do
        let(:newer_seller) { create(:user, created_at: 23.months.ago) }
        let(:newer_product) { create(:product, user: newer_seller) }
        let!(:newer_purchase) { create(:purchase, link: newer_product, purchase_state: "in_progress") }

        it "does NOT pause payouts but flags for review when threshold is exceeded" do
          create_list(:failed_purchase, 5, link: newer_product, price_cents: 250)

          expect do
            newer_purchase.mark_failed!
          end.to change { InternalNotificationWorker.jobs.size }.by(1)

          expect(newer_seller.reload.payouts_paused_internally).to be(false)
          expect(newer_seller.payouts_paused_by_source).to be_nil
        end
      end

      context "when total failed amount is below threshold" do
        it "does not pause payouts for the seller" do
          create_list(:failed_purchase, 3, link: product, price_cents: 250)
          purchase.mark_failed!

          expect(seller.reload.payouts_paused_internally).to be(false)
          expect(seller.payouts_paused_by_source).to be nil
        end
      end

      context "when total failed amount is above threshold" do
        it "does NOT pause payouts internally (informational only)" do
          create_list(:failed_purchase, 5, link: product, price_cents: 250)
          purchase.mark_failed!

          expect(seller.reload.payouts_paused_internally).to be(false)
          expect(seller.payouts_paused_by_source).to be_nil
        end

        it "creates a review comment with the failed amount (no pause)" do
          create_list(:failed_purchase, 5, link: product, price_cents: 250)
          purchase.mark_failed!

          comment = seller.comments.last
          expect(comment.content).to eq("High volume of failed purchases ($13.50 USD in 60 minutes) — flagged for review (payouts NOT paused).")
          expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_ON_PROBATION)
          expect(comment.author_name).to eq("pause_payouts_for_seller_based_on_recent_failures")
        end

        context "when some purchases are outside the watch window" do
          it "does not flag or comment" do
            travel_to Time.current do
              create_list(:failed_purchase, 2, link: product, price_cents: 250)
              create_list(:failed_purchase, 3, link: product, price_cents: 250, created_at: 61.minutes.ago)
              expect do
                purchase.mark_failed!
              end.not_to change { InternalNotificationWorker.jobs.size }
              expect(seller.reload.payouts_paused_internally).to be(false)
              expect(seller.payouts_paused_by_source).to be nil
            end
          end
        end
      end

      context "when redis keys are not set" do
        before do
          $redis.del(RedisKey.failed_seller_purchases_watch_minutes)
          $redis.del(RedisKey.max_seller_failed_purchases_price_cents)
        end

        context "when total failed amount is below default threshold" do
          it "does not flag the seller" do
            # default max amount is $2000
            create_list(:failed_purchase, 5, link: product, price_cents: 200_00)
            purchase.mark_failed!

            expect(seller.reload.payouts_paused_internally).to be(false)
            expect(seller.payouts_paused_by_source).to be nil
          end
        end

        context "when total failed amount is above default threshold" do
          it "flags for review but does NOT pause payouts" do
            # default max amount is $2000
            create_list(:failed_purchase, 11, link: product, price_cents: 200_00)

            expect do
              purchase.mark_failed!
            end.to change { InternalNotificationWorker.jobs.size }.by(1)

            expect(seller.reload.payouts_paused_internally).to be(false)
            expect(seller.payouts_paused_by_source).to be_nil
          end
        end
      end
    end
  end

  describe "#charge_processor_fingerprint" do
    context "when charge_processor_id is 'stripe'" do
      let(:purchase) { build(:purchase) }

      it "returns stripe fingerprint" do
        expect(purchase.charge_processor_fingerprint).to eq(purchase.stripe_fingerprint)
      end
    end

    context "when charge_processor_id is not 'stripe'" do
      let(:purchase) { build(:purchase, charge_processor_id: PaypalChargeProcessor.charge_processor_id, card_visual: "paypal-email@example.com") }

      it "returns card visual" do
        expect(purchase.charge_processor_fingerprint).to eq("paypal-email@example.com")
      end
    end
  end

  describe "#block_fraudulent_free_purchases!" do
    before do
      @product = create(:product, price_cents: 0)

      create_list(:purchase, 2, link: @product, ip_address: "127.0.0.1")
    end

    context "when number of free purchases of the same product from same IP address exceeds the threshold" do
      context "when the purchase happens within the configured time limit" do
        it "blocks the ip_address" do
          freeze_time do
            expect do
              purchase = create(:purchase, link: @product, ip_address: "127.0.0.1", purchase_state: "in_progress")
              purchase.mark_successful!
            end.to change { PlatformBlock.count }.from(0).to(1)

            expect(PlatformBlock.pluck(:object_type, :object_value)).to eq [["ip_address", "127.0.0.1"]]
            expect(PlatformBlock.ip_address.active.find_by(object_value: "127.0.0.1").expires_at.to_i).to eq 24.hours.from_now.to_i
          end
        end
      end

      context "when the purchase happens outside the configured time limit" do
        it "doesn't block the ip_address" do
          travel_to(5.hours.from_now) do
            expect do
              purchase = create(:purchase, link: @product, ip_address: "127.0.0.1", purchase_state: "in_progress")
              purchase.mark_successful!
            end.not_to change { PlatformBlock.count }
          end
        end
      end
    end

    context "when the purchase is created for another product" do
      it "doesn't block the ip_address" do
        expect do
          purchase = create(:purchase, ip_address: "127.0.0.1", purchase_state: "in_progress")
          purchase.mark_successful!
        end.not_to change { PlatformBlock.count }
      end
    end

    context "when the purchase is created from another ip_address" do
      it "doesn't block the ip_address" do
        expect do
          purchase = create(:purchase, link: @product, ip_address: "127.0.0.2", purchase_state: "in_progress")
          purchase.mark_successful!
        end.not_to change { PlatformBlock.count }
      end
    end

    context "when purchase is not free" do
      it "doesn't block the ip_address" do
        expect do
          purchase = create(:purchase, price_cents: 100, link: @product, ip_address: "127.0.0.1", purchase_state: "in_progress")
          purchase.mark_successful!
        end.not_to change { PlatformBlock.count }
      end
    end
  end

  describe "#suspend_buyer_on_fraudulent_card_decline!" do
    before do
      Feature.activate(:suspend_fraudulent_buyers)

      @buyer = create(:user)
      @purchase = build(:purchase_in_progress,
                        email: "sam@example.com",
                        error_code: PurchaseErrorCode::CARD_DECLINED_FRAUDULENT,
                        purchaser: @buyer)
    end

    context "when the error code is not CARD_DECLINED_FRAUDULENT" do
      it "doesn't suspend the buyer" do
        @purchase.error_code = PurchaseErrorCode::STRIPE_INSUFFICIENT_FUNDS

        expect { @purchase.mark_failed! }.not_to change { @buyer.reload.suspended? }
      end
    end

    context "when the buyer account was created more than 6 hours ago" do
      it "doesn't suspend the buyer" do
        @buyer.update!(created_at: 7.hours.ago)

        expect { @purchase.mark_failed! }.not_to change { @buyer.reload.suspended? }
      end
    end

    context "when the error code is CARD_DECLINED_FRAUDULENT" do
      context "when buyer account was created less than 6 hours ago" do
        it "suspends the buyer" do
          expect do
            @purchase.mark_failed!
            expect(@buyer.comments.last.author_name).to eq("fraudulent_purchases_blocker")
          end.to change { @buyer.reload.suspended? }.from(false).to(true)
        end
      end
    end

    context "when the buyer is already suspended for fraud" do
      before do
        @buyer.flag_for_fraud!(author_name: "admin")
        @buyer.suspend_for_fraud!(author_name: "admin")
      end

      it "does not attempt an invalid state transition" do
        expect { @purchase.mark_failed! }.not_to raise_error
        expect(@buyer.reload.suspended_for_fraud?).to be(true)
      end
    end

    context "when the buyer is already suspended for tos violation" do
      before do
        @buyer.update_column(:user_risk_state, "suspended_for_tos_violation")
      end

      it "does not attempt an invalid state transition" do
        expect { @purchase.mark_failed! }.not_to raise_error
        expect(@buyer.reload.suspended_for_tos_violation?).to be(true)
      end
    end

    context "when the buyer is already flagged for fraud" do
      before do
        @buyer.flag_for_fraud!(author_name: "admin")
      end

      it "suspends the buyer without re-flagging" do
        expect { @purchase.mark_failed! }.to change { @buyer.reload.suspended_for_fraud? }.from(false).to(true)
      end
    end
  end

  describe "#block_buyer_based_on_chargeback_count!" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:buyer) { create(:user) }
    let(:purchase) { create(:purchase, link: product, email: "repeat-offender@example.com", purchaser: buyer) }

    def create_chargebacked_purchases_by_email(count, email)
      count.times do
        p = create(:purchase)
        p.update_columns(chargeback_date: Time.current, email: email)
      end
    end

    def create_chargebacked_purchases_by_purchaser(count, purchaser)
      count.times do
        p = create(:purchase, purchaser: purchaser)
        p.update_column(:chargeback_date, Time.current)
      end
    end

    context "when buyer has fewer than 5 chargebacks" do
      before do
        create_chargebacked_purchases_by_email(4, "repeat-offender@example.com")
      end

      it "does not block the buyer" do
        expect { purchase.block_buyer_based_on_chargeback_count! }.not_to change { PlatformBlock.count }
      end
    end

    context "when buyer has 5 chargebacks by email" do
      before do
        create_chargebacked_purchases_by_email(5, "repeat-offender@example.com")
      end

      it "blocks the buyer" do
        expect { purchase.block_buyer_based_on_chargeback_count! }.to change { PlatformBlock.count }
        expect(purchase.buyer_blocked?).to be true
      end

      it "creates a comment with the chargeback count" do
        purchase.block_buyer_based_on_chargeback_count!

        comment = purchase.comments.last
        expect(comment.content).to include("Auto-blocked")
        expect(comment.content).to include("5 by email")
      end
    end

    context "when buyer is already blocked" do
      before do
        create_chargebacked_purchases_by_email(5, "repeat-offender@example.com")
        purchase.block_buyer!
      end

      it "does not re-block the buyer" do
        expect { purchase.block_buyer_based_on_chargeback_count! }.not_to change { PlatformBlock.count }
      end
    end

    context "when buyer has 5 chargebacks by purchaser_id with different email" do
      before do
        create_chargebacked_purchases_by_purchaser(5, buyer)
      end

      it "blocks the buyer" do
        expect { purchase.block_buyer_based_on_chargeback_count! }.to change { PlatformBlock.count }
        expect(purchase.buyer_blocked?).to be true
      end
    end
  end

  describe "#pause_payouts_for_seller_based_on_chargeback_rate!" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product) }

    context "when seller payouts are already paused internally" do
      before do
        seller.update!(payouts_paused_internally: true)
        allow(seller).to receive(:lost_chargebacks).and_return({ volume: "4.2%", count: "15.0%" })
      end

      it "does not change the payout pause source" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!
        expect(seller.reload.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
      end

      it "does not create additional comments" do
        expect do
          purchase.pause_payouts_for_seller_based_on_chargeback_rate!
        end.to_not change { seller.comments.count }
      end
    end

    context "when chargeback volume is 'NA'" do
      before do
        allow(seller).to receive(:lost_chargebacks).and_return({ volume: "NA", count: "0.0%" })
      end

      it "does not pause payouts" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!

        expect(seller.reload.payouts_paused_internally).to be(false)
        expect(seller.payouts_paused_by_source).to be_nil
      end

      it "does not create a comment" do
        expect do
          purchase.pause_payouts_for_seller_based_on_chargeback_rate!
        end.to_not change { seller.comments.count }
      end
    end

    # The threshold is a policy number that has already moved once (3% to 1%), so these boundary
    # cases read it from the constant rather than hardcoding a percentage. A future change to the
    # policy should not need this file edited to keep the boundary covered.
    context "when chargeback volume is exactly at the threshold" do
      before do
        allow(seller).to receive(:lost_chargebacks)
          .and_return({ volume: "#{User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS}%", count: "10.0%" })
      end

      it "does not pause payouts" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!

        expect(seller.reload.payouts_paused_internally?).to be(false)
        expect(seller.payouts_paused_by_source).to be_nil
      end

      it "does not create a comment" do
        expect do
          purchase.pause_payouts_for_seller_based_on_chargeback_rate!
        end.to_not change { seller.comments.count }
      end
    end

    context "when chargeback volume is below the threshold" do
      before do
        allow(seller).to receive(:lost_chargebacks)
          .and_return({ volume: "#{User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS - 0.5}%", count: "5.0%" })
      end

      it "does not pause payouts" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!

        expect(seller.reload.payouts_paused_internally?).to be(false)
        expect(seller.payouts_paused_by_source).to be_nil
      end

      it "does not create a comment" do
        expect do
          purchase.pause_payouts_for_seller_based_on_chargeback_rate!
        end.to_not change { seller.comments.count }
      end
    end

    # 2.5% used to be a passing rate under the old 3% threshold. Pinning it as a pause is what
    # actually distinguishes the 1% policy from the 3% one.
    context "when chargeback volume is 2.5%, which the old 3% threshold allowed" do
      before do
        allow(seller).to receive(:lost_chargebacks).and_return({ volume: "2.5%", count: "5.0%" })
      end

      it "pauses payouts internally" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!

        expect(seller.reload.payouts_paused_internally?).to be(true)
        expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      end

      it "creates a comment naming the 1% limit" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!

        expect(seller.comments.last.content)
          .to eq("Payouts automatically paused due to chargeback rate (2.5%) exceeding 1.0% volume.")
      end
    end

    context "when chargeback volume exceeds the threshold" do
      before do
        allow(seller).to receive(:lost_chargebacks).and_return({ volume: "4.2%", count: "15.0%" })
      end

      it "pauses payouts internally" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!

        expect(seller.reload.payouts_paused_internally?).to be(true)
        expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      end

      it "creates a comment with the chargeback rate" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!

        comment = seller.comments.last
        expect(comment.content).to eq("Payouts automatically paused due to chargeback rate (4.2%) exceeding 1.0% volume.")
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_ON_PROBATION)
        expect(comment.author_name).to eq("pause_payouts_for_seller_based_on_chargeback_rate")
      end

      # The pause flag alone says "system" without saying WHICH automatic check holds the account —
      # only the comment does. If the flag could land without its comment,
      # ReleaseChargebackRatePayoutPauseForSellerJob could read an older comment as the current
      # reason and lift a hold that was just applied, so the two writes have to be one unit.
      it "rolls the pause flag back when its identifying comment cannot be written" do
        relation = seller.comments
        allow(seller).to receive(:comments).and_return(relation)
        allow(relation).to receive(:create).and_raise(ActiveRecord::RecordInvalid.new(Comment.new))

        expect do
          purchase.pause_payouts_for_seller_based_on_chargeback_rate!
        end.to raise_error(ActiveRecord::RecordInvalid)

        expect(seller.reload.payouts_paused_internally?).to be(false)
      end
    end

    context "when chargeback volume is far above the threshold" do
      before do
        allow(seller).to receive(:lost_chargebacks).and_return({ volume: "15.7%", count: "25.0%" })
      end

      it "pauses payouts internally" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!

        expect(seller.reload.payouts_paused_internally?).to be(true)
        expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      end

      it "creates a comment with the correct chargeback rate" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!

        comment = seller.comments.last
        expect(comment.content).to eq("Payouts automatically paused due to chargeback rate (15.7%) exceeding 1.0% volume.")
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_ON_PROBATION)
        expect(comment.author_name).to eq("pause_payouts_for_seller_based_on_chargeback_rate")
      end
    end

    context "edge case: when chargeback volume is just above the threshold" do
      before do
        allow(seller).to receive(:lost_chargebacks).and_return({ volume: "1.1%", count: "8.0%" })
      end

      it "pauses payouts internally" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!

        expect(seller.reload.payouts_paused_internally?).to be(true)
        expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      end

      it "creates a comment with the chargeback rate" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!

        comment = seller.comments.last
        expect(comment.content).to eq("Payouts automatically paused due to chargeback rate (1.1%) exceeding 1.0% volume.")
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_ON_PROBATION)
        expect(comment.author_name).to eq("pause_payouts_for_seller_based_on_chargeback_rate")
      end
    end
  end

  describe "#enforce_refund_policy_for_seller_based_on_dispute_rate!" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product) }

    # settled_buyers_count defaults to settled_count (each purchase from a different buyer)
    # so existing scenarios read the same; the installment trigger case overrides it.
    def stub_dispute_stats(settled_count:, disputing_buyers_count:, settled_buyers_count: settled_count)
      rate = settled_buyers_count > 0 ? disputing_buyers_count * 100.0 / settled_buyers_count : nil
      allow(seller).to receive(:dispute_rate_stats).and_return({ settled_count:, settled_buyers_count:, disputing_buyers_count:, rate: })
    end

    context "when the seller already has an enforced refund policy" do
      before do
        seller.update!(refund_policy_enforced: true)
        stub_dispute_stats(settled_count: 100, disputing_buyers_count: 50)
      end

      it "does not create additional comments" do
        expect do
          purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!
        end.to_not change { seller.comments.count }
      end

      it "does not email the seller again" do
        expect do
          purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!
        end.to_not have_enqueued_mail(ContactingCreatorMailer, :refund_policy_enforced_notification)
      end

      it "does not modify the refund policy" do
        seller.refund_policy.update!(max_refund_period_in_days: 7)

        expect do
          purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!
        end.to_not change { seller.refund_policy.reload.max_refund_period_in_days }
      end
    end

    context "when the seller has fewer settled purchases than the minimum" do
      before do
        stub_dispute_stats(settled_count: 24, disputing_buyers_count: 10)
      end

      it "does not enforce the refund policy" do
        purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!

        expect(seller.reload.refund_policy_enforced?).to be(false)
      end

      it "does not create a comment" do
        expect do
          purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!
        end.to_not change { seller.comments.count }
      end
    end

    context "when the seller has fewer disputing buyers than the minimum" do
      before do
        stub_dispute_stats(settled_count: 100, disputing_buyers_count: 2)
      end

      it "does not enforce the refund policy" do
        purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!

        expect(seller.reload.refund_policy_enforced?).to be(false)
      end
    end

    context "when one buyer disputes multiple installments of the same purchase" do
      before do
        # The trigger case for #6171: a ~250-sale seller with one buyer who disputed both
        # installments of a course. As raw purchases that was 2 disputes; as unique buyers
        # it is 1 disputing buyer, which stays under the 3-buyer minimum, so no enforcement.
        stub_dispute_stats(settled_count: 250, settled_buyers_count: 249, disputing_buyers_count: 1)
      end

      it "does not enforce the refund policy" do
        purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!

        expect(seller.reload.refund_policy_enforced?).to be(false)
      end

      it "does not create a comment" do
        expect do
          purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!
        end.to_not change { seller.comments.count }
      end
    end

    context "when the dispute rate is exactly 1.0%" do
      before do
        stub_dispute_stats(settled_count: 300, disputing_buyers_count: 3)
      end

      it "does not enforce the refund policy" do
        purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!

        expect(seller.reload.refund_policy_enforced?).to be(false)
      end

      it "does not create a comment" do
        expect do
          purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!
        end.to_not change { seller.comments.count }
      end
    end

    context "when the dispute rate exceeds 1.0%" do
      before do
        # Three distinct buyers disputed out of 100 unique buyers: 3% > 1%, so enforce.
        stub_dispute_stats(settled_count: 100, disputing_buyers_count: 3)
      end

      it "sets the refund_policy_enforced flag" do
        purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!

        expect(seller.reload.refund_policy_enforced?).to be(true)
      end

      it "creates a comment with the dispute rate" do
        purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!

        comment = seller.comments.last
        expect(comment.content).to include("dispute rate 3.0%")
        expect(comment.content).to include("3 disputing buyers / 100 unique buyers")
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_ON_PROBATION)
        expect(comment.author_name).to eq("enforce_refund_policy_for_seller_based_on_dispute_rate")
      end

      it "emails the seller about the policy change" do
        expect do
          purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!
        end.to have_enqueued_mail(ContactingCreatorMailer, :refund_policy_enforced_notification).with(seller.id)
      end

      context "when the seller's refund policy is 'No refunds allowed' (0 days)" do
        before do
          seller.refund_policy.update!(max_refund_period_in_days: 0)
        end

        it "bumps the refund period to 30 days" do
          purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!

          expect(seller.refund_policy.reload.max_refund_period_in_days).to eq(30)
        end
      end

      context "when the seller's refund policy already allows refunds" do
        before do
          seller.refund_policy.update!(max_refund_period_in_days: 183)
        end

        it "keeps the existing refund period" do
          purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!

          expect(seller.refund_policy.reload.max_refund_period_in_days).to eq(183)
        end
      end

      it "is idempotent when called twice" do
        purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!

        expect do
          purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!
        end.to_not change { seller.comments.count }
      end

      context "when the audit comment fails to save" do
        before do
          seller.refund_policy.update!(max_refund_period_in_days: 0)
          allow(seller.comments).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)
        end

        it "rolls back the enforcement flag and the policy bump so a retry can run the handler again" do
          expect do
            purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!
          end.to raise_error(ActiveRecord::RecordInvalid)

          expect(seller.reload.refund_policy_enforced?).to be(false)
          expect(seller.refund_policy.reload.max_refund_period_in_days).to eq(0)
        end
      end
    end

    context "when the purchase has no seller" do
      it "does nothing" do
        allow(purchase).to receive(:seller).and_return(nil)

        expect { purchase.enforce_refund_policy_for_seller_based_on_dispute_rate! }.to_not raise_error
      end
    end
  end
end
