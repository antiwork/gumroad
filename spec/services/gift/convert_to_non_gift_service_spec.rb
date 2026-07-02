# frozen_string_literal: true

require "spec_helper"

describe Gift::ConvertToNonGiftService do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:payer) { create(:user, email: "payer@example.com") }
  let(:gifter_purchase) { create(:purchase, link: product, seller:, purchaser: payer, is_gift_sender_purchase: true) }
  let(:giftee_purchase) { create(:purchase, :gift_receiver, link: product, seller:) }
  let(:gift) do
    create(:gift, link: product, gifter_purchase:, giftee_purchase:,
                  gifter_email: "payer@example.com", giftee_email: "giftee@example.com")
  end

  def build_service(gifter_signed_off: true, giftee_signed_off: true, reason: nil)
    described_class.new(gift:, gifter_signed_off:, giftee_signed_off:, reason:)
  end

  describe "#process!" do
    context "confirmation gate" do
      it "raises when the gifter has not signed off" do
        expect { build_service(gifter_signed_off: false).process! }
          .to raise_error(described_class::ConfirmationRequiredError, /gifter/)
      end

      it "raises when the giftee has not signed off" do
        expect { build_service(giftee_signed_off: false).process! }
          .to raise_error(described_class::ConfirmationRequiredError, /giftee/)
      end

      it "raises when a sign-off is truthy but not literally true" do
        expect { build_service(gifter_signed_off: "yes").process! }
          .to raise_error(described_class::ConfirmationRequiredError)
      end

      it "does not mutate the purchases when the gate fails" do
        expect { build_service(giftee_signed_off: false).process! rescue nil }
          .not_to change { gifter_purchase.reload.is_gift_sender_purchase? }
      end
    end

    context "for a one-off gift" do
      it "clears the gift-sender flag on the payer leg and returns converted" do
        result = build_service.process!

        expect(result.converted).to be(true)
        expect(gifter_purchase.reload.is_gift_sender_purchase?).to be(false)
      end

      it "makes Purchase#gift resolve to nil for the payer leg" do
        build_service.process!

        expect(gifter_purchase.reload.gift).to be_nil
      end

      it "leaves the giftee receiver leg untouched so its access stays intact" do
        build_service.process!

        expect(giftee_purchase.reload.is_gift_receiver_purchase?).to be(true)
        expect(giftee_purchase.reload.purchase_state).to eq("gift_receiver_purchase_successful")
        expect(Purchase.for_library).to include(gifter_purchase, giftee_purchase)
      end

      it "retains the Gift record for audit history" do
        build_service.process!
        expect(Gift.exists?(gift.id)).to be(true)
      end

      it "logs an audit comment on both purchases and the payer account" do
        build_service(reason: "gumroad-private#841").process!

        gifter_comment = gifter_purchase.reload.comments.last
        expect(gifter_comment.comment_type).to eq(Comment::COMMENT_TYPE_NOTE)
        expect(gifter_comment.author_id).to eq(GUMROAD_ADMIN_ID)
        expect(gifter_comment.content).to include("converted to a regular (non-gift) purchase")
        expect(gifter_comment.content).to include("gumroad-private#841")

        expect(giftee_purchase.reload.comments.last.content).to include("converted to a regular")
        expect(payer.reload.comments.last.content).to include("converted to a regular")
      end
    end

    context "for a gifted subscription" do
      let(:subscription) { create(:subscription, link: product, user: nil) }
      let!(:gifter_purchase) do
        create(:membership_purchase, link: product, seller:, subscription:, purchaser: payer,
                                     email: "payer@example.com", is_gift_sender_purchase: true, gift_given: gift)
      end
      let(:gift) { create(:gift, link: product, giftee_email: "giftee@example.com", gifter_email: "payer@example.com") }
      let(:giftee_purchase) { nil }

      it "flips Subscription#gift? from true to false" do
        expect(subscription.reload.gift?).to be(true)

        build_service.process!

        expect(subscription.reload.gift?).to be(false)
      end

      it "resolves the subscription email to the paying buyer instead of the giftee" do
        build_service.process!

        expect(subscription.reload.email).to eq("payer@example.com")
      end

      it "returns the subscription in the result" do
        result = build_service.process!
        expect(result.subscription).to eq(subscription)
      end

      context "when the subscription has a gift-receiver access leg" do
        let(:giftee) { create(:user, email: "giftee@example.com") }
        let!(:receiver_leg) do
          create(:membership_purchase, :gift_receiver, link: product, seller:, subscription:,
                                                       purchaser: giftee, email: "giftee@example.com")
        end

        before { subscription.update!(user: giftee) }

        it "keeps the receiver flag so the giftee's library access is preserved" do
          build_service.process!

          expect(receiver_leg.reload.is_gift_receiver_purchase?).to be(true)
          expect(Purchase.for_library).to include(receiver_leg)
        end

        it "re-owns the subscription to the payer so renewal comms leave the giftee" do
          expect(subscription.reload.email).to eq("giftee@example.com")

          build_service.process!

          expect(subscription.reload.user).to eq(payer)
          expect(subscription.reload.email).to eq("payer@example.com")
        end
      end

      context "when the payer is a guest buyer (nil purchaser)" do
        let!(:gifter_purchase) do
          create(:membership_purchase, link: product, seller:, subscription:, purchaser: nil,
                                       email: "payer@example.com", is_gift_sender_purchase: true, gift_given: gift)
        end

        it "sets the subscription user to nil and resolves email via the payer purchase" do
          result = build_service.process!

          expect(result.converted).to be(true)
          expect(subscription.reload.user).to be_nil
          expect(subscription.reload.gift?).to be(false)
          expect(subscription.reload.email).to eq("payer@example.com")
        end
      end

      context "when the paying buyer is a guest (nil purchaser)" do
        let!(:gifter_purchase) do
          create(:membership_purchase, link: product, seller:, subscription:, purchaser: nil,
                                       email: "payer@example.com", is_gift_sender_purchase: true, gift_given: gift)
        end

        before { subscription.update!(user: create(:user, email: "giftee@example.com")) }

        it "clears the subscription owner and resolves email to the payer via the original purchase" do
          expect(subscription.reload.gift?).to be(true)
          expect(subscription.reload.email).to eq("giftee@example.com")

          build_service.process!

          expect(subscription.reload.user).to be_nil
          expect(subscription.reload.email).to eq("payer@example.com")
        end
      end

      context "when the payer purchase has a saved card", :vcr do
        let(:credit_card) { create(:credit_card) }
        let!(:gifter_purchase) do
          create(:membership_purchase, link: product, seller:, subscription:, purchaser: payer,
                                       email: "payer@example.com", credit_card:,
                                       is_gift_sender_purchase: true, gift_given: gift)
        end

        it "moves the payer's card onto the subscription so renewals can bill the payer" do
          expect(subscription.reload.credit_card).to be_nil

          build_service.process!

          expect(subscription.reload.credit_card).to eq(credit_card)
        end
      end

      context "when the giftee added their own card and the payer has none", :vcr do
        let(:giftee_card) { create(:credit_card) }
        let!(:gifter_purchase) do
          create(:membership_purchase, link: product, seller:, subscription:, purchaser: payer,
                                       email: "payer@example.com",
                                       is_gift_sender_purchase: true, gift_given: gift)
        end

        before { subscription.update!(credit_card: giftee_card) }

        it "clears the stale giftee card so renewals do not keep billing the giftee" do
          expect(subscription.reload.credit_card).to eq(giftee_card)

          build_service.process!

          expect(subscription.reload.credit_card).to be_nil
        end
      end
    end

    context "idempotency" do
      it "returns already_converted on a second run without error" do
        build_service.process!

        result = build_service.process!
        expect(result.converted).to be(false)
        expect(result.already_converted).to be(true)
      end
    end

    context "when the gift has no gifter purchase" do
      let(:gift) { create(:gift, link: product, gifter_purchase: nil, giftee_purchase:) }

      it "raises NotConvertibleError" do
        expect { build_service.process! }.to raise_error(described_class::NotConvertibleError)
      end
    end
  end
end
