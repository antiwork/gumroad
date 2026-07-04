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

  describe "email blocking on fraud" do
    context "for a fraudulent transaction" do
      it "blocks the email" do
        purchase = build(:purchase_in_progress,
                         email: "foo@example.com",
                         error_code: PurchaseErrorCode::FRAUD_RELATED_ERROR_CODES.sample)

        purchase.mark_failed!

        expect(purchase.blocked_by_email?).to be true
        expect(purchase.blocked_by_email_object&.object_value).to eq("foo@example.com")
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
  end

  describe "#mark_failed" do
    context "when the purchase fails due to a fraud related reason" do
      let(:purchaser) { create(:user, email: "purchaser@example.com") }
      let(:purchase) { create(:purchase, purchaser:, email: "another-email@example.com", purchase_state: "in_progress", stripe_error_code: "card_declined_lost_card", charge_processor_id: StripeChargeProcessor.charge_processor_id) }
      let(:expected_blocked_objects) do [
        ["email", "purchaser@example.com"],
        ["browser_guid", purchase.browser_guid],
        ["email", "another-email@example.com"],
        ["ip_address", purchase.ip_address],
        ["charge_processor_fingerprint", purchase.stripe_fingerprint]
      ] end

      it "blocks buyer's email, browser_guid, ip_address and stripe_fingerprint" do
        expect do
          purchase.mark_failed
        end.to change { PlatformBlock.count }.from(0).to(5)
        expect(PlatformBlock.pluck(:object_type, :object_value)).to match_array(expected_blocked_objects)
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

    context "when chargeback volume is at 3.0%" do
      before do
        allow(seller).to receive(:lost_chargebacks).and_return({ volume: "3.0%", count: "10.0%" })
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

    context "when chargeback volume is below 3.0%" do
      before do
        allow(seller).to receive(:lost_chargebacks).and_return({ volume: "2.5%", count: "5.0%" })
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

    context "when chargeback volume exceeds 3.0%" do
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
        expect(comment.content).to eq("Payouts automatically paused due to chargeback rate (4.2%) exceeding 3.0% volume.")
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_ON_PROBATION)
        expect(comment.author_name).to eq("pause_payouts_for_seller_based_on_chargeback_rate")
      end
    end

    context "when chargeback volume is significantly above 3.0%" do
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
        expect(comment.content).to eq("Payouts automatically paused due to chargeback rate (15.7%) exceeding 3.0% volume.")
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_ON_PROBATION)
        expect(comment.author_name).to eq("pause_payouts_for_seller_based_on_chargeback_rate")
      end
    end

    context "edge case: when chargeback volume is just above 3.0%" do
      before do
        allow(seller).to receive(:lost_chargebacks).and_return({ volume: "3.1%", count: "8.0%" })
      end

      it "pauses payouts internally" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!

        expect(seller.reload.payouts_paused_internally?).to be(true)
        expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      end

      it "creates a comment with the chargeback rate" do
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!

        comment = seller.comments.last
        expect(comment.content).to eq("Payouts automatically paused due to chargeback rate (3.1%) exceeding 3.0% volume.")
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_ON_PROBATION)
        expect(comment.author_name).to eq("pause_payouts_for_seller_based_on_chargeback_rate")
      end
    end
  end

  describe "#enforce_refund_policy_for_seller_based_on_dispute_rate!" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product) }

    def stub_dispute_stats(settled_count:, disputed_count:)
      rate = settled_count > 0 ? disputed_count * 100.0 / settled_count : nil
      allow(seller).to receive(:dispute_rate_stats).and_return({ settled_count:, disputed_count:, rate: })
    end

    context "when the seller already has an enforced refund policy" do
      before do
        seller.update!(refund_policy_enforced: true)
        stub_dispute_stats(settled_count: 100, disputed_count: 50)
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
        stub_dispute_stats(settled_count: 24, disputed_count: 10)
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

    context "when the seller has fewer disputes than the minimum" do
      before do
        stub_dispute_stats(settled_count: 100, disputed_count: 2)
      end

      it "does not enforce the refund policy" do
        purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!

        expect(seller.reload.refund_policy_enforced?).to be(false)
      end
    end

    context "when the dispute rate is exactly 1.0%" do
      before do
        stub_dispute_stats(settled_count: 300, disputed_count: 3)
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
        stub_dispute_stats(settled_count: 100, disputed_count: 3)
      end

      it "sets the refund_policy_enforced flag" do
        purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!

        expect(seller.reload.refund_policy_enforced?).to be(true)
      end

      it "creates a comment with the dispute rate" do
        purchase.enforce_refund_policy_for_seller_based_on_dispute_rate!

        comment = seller.comments.last
        expect(comment.content).to include("dispute rate 3.0%")
        expect(comment.content).to include("3 disputes / 100 settled sales")
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
