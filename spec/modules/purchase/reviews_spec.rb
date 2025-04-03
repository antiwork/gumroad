# frozen_string_literal: true

require "spec_helper"

describe Purchase::Reviews do
  describe "#post_review" do
    before do
      @purchase = create(:purchase)
      @rating = 3
      @message = "This is a review message"
    end

    context "when there is an existing product_review" do
      it "updates the existing product_review with the provided rating" do
        product_review = create(:product_review, purchase: @purchase, rating: 1)
        result = @purchase.post_review(@rating, @message)
        expect(result).to eq(true)
        product_review.reload
        expect(product_review.rating).to eq(@rating)
        expect(product_review.message).to eq(@message)
      end

      it "updates the product review of the original purchase in case of recurring purchase of a subscription" do
        subscription_product = create(:subscription_product)
        subscription = create(:subscription, link: subscription_product)
        original_purchase = create(:purchase, link: subscription_product, is_original_subscription_purchase: true, subscription:)
        create(:product_review, rating: 1, purchase: original_purchase)
        recurring_purchase = create(:purchase, link: subscription_product, subscription:)
        subscription.purchases << original_purchase << recurring_purchase

        recurring_purchase.reload
        result = recurring_purchase.post_review(@rating)
        expect(result).to eq(true)
        original_purchase.reload
        expect(original_purchase.product_review.rating).to eq(@rating)
        expect(original_purchase.product_review.message).to be_nil
      end

      it "does not update the rating if the purchase does not allow reviews to be counted" do
        product_review = create(:product_review, purchase: @purchase, rating: 1, message: nil)
        @purchase.update!(stripe_refunded: true)
        expect { @purchase.post_review(5, @message) }.to raise_error(ProductReview::RestrictedOperationError)
        product_review.reload
        expect(product_review.rating).to eq(1)
        expect(product_review.message).to be_nil
      end
    end

    context "when there is no existing product_review" do
      it "adds a review for a purchase that allows reviews to be counted" do
        expect(@purchase).to receive(:add_review!).with(@rating, nil)
        result = @purchase.post_review(@rating)
        expect(result).to eq(true)
      end

      it "does not add review when the purchase does not allow reviews to be counted" do
        allow(@purchase).to receive(:allows_review_to_be_counted?).and_return(false)
        expect(@purchase).not_to receive(:add_review!)
        result = @purchase.post_review(@rating)
        expect(result).to eq(false)
        expect(@purchase.product_review).to be_blank
      end
    end
  end

  describe "#add_review!" do
    let(:purchase) { create(:purchase) }

    it "creates a ProductReview" do
      expect(purchase.product_review).to be(nil)

      expect do
        purchase.add_review!(3, @message)
      end.to have_enqueued_mail(ContactingCreatorMailer, :review_submitted).with { purchase.product_review.id }

      expect(purchase.product_review).not_to be(nil)
      expect(purchase.product_review.rating).to eq(3)
      expect(purchase.product_review.message).to eq(@message)
    end

    context "review notifications are disabled" do
      before { purchase.seller.update(disable_reviews_email: true) }

      it "doesn't enqueue an email" do
        expect do
          purchase.add_review!(3, @message)
        end.to_not have_enqueued_mail(ContactingCreatorMailer, :review_submitted).with { purchase.product_review.id }
      end
    end

    context "review already exists for the purchase" do
      let(:review) { create(:product_review) }

      it "raises an exception" do
        expect { review.purchase.add_review!(1) }.to raise_error(ActiveRecord::RecordInvalid, /Purchase has already been taken/)
      end
    end

    it "saves the link_id associated with the purchase on the product review" do
      purchase = create(:purchase)
      purchase.add_review!(3)

      expect(purchase.product_review.link_id).to eq(purchase.link_id)
    end

    it "adds product review to the original purchase in case of recurring purchase of a subscription" do
      subscription_product = create(:subscription_product)
      subscription = create(:subscription, link: subscription_product)
      original_purchase = create(:purchase, link: subscription_product, is_original_subscription_purchase: true, subscription:)
      recurring_purchase = create(:purchase, link: subscription_product, subscription:)
      subscription.purchases << original_purchase << recurring_purchase
      subscription.save!

      recurring_purchase.add_review!(3)
      expect(original_purchase.reload.product_review.rating).to eq(3)
    end
  end

  describe "#update_product_review_stat" do
    it "does not update the product_review_stat after update if no product review exists" do
      purchase = create(:purchase)

      expect(purchase.link).not_to receive(:update_review_stat_via_purchase_changes)
      purchase.stripe_refunded = true
      purchase.save!
    end

    it "does not update the product_review_stat after update if no changes have been saved" do
      purchase = create(:purchase)

      expect(purchase.link).not_to receive(:update_review_stat_via_purchase_changes)
      purchase.save(id: purchase.id)
      purchase.save!
    end

    it "updates the product_review_stat after update" do
      purchase = create(:purchase)
      purchase.add_review!(3)

      expect(purchase.link).to receive(:update_review_stat_via_purchase_changes).with(
        hash_including("stripe_refunded" => [nil, true]),
        product_review: purchase.product_review
      )
      purchase.stripe_refunded = true
      purchase.save!
    end
  end

  describe "#refund_purchase! effect on reviews" do
    it "updates product_review_stat" do
      purchase = create(:purchase)
      product = purchase.link

      expect(product.average_rating).to eq(0)
      purchase.add_review!(3)
      expect(product.average_rating).to eq(3)

      purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents), purchase.seller.id)
      expect(product.average_rating).to eq(0)
      expect(purchase.product_review).to be_deleted
    end
  end

  describe "revoking/unrevoking access" do
    it "updates the product review" do
      purchase = create(:purchase, price_cents: 0)
      product = purchase.link

      expect(product.average_rating).to eq(0)
      purchase.add_review!(3)
      expect(product.average_rating).to eq(3)

      purchase.update!(is_access_revoked: true)
      expect(product.average_rating).to eq(0)
      expect(purchase.product_review).to be_deleted

      purchase.update!(is_access_revoked: false)
      expect(product.average_rating).to eq(3)
      expect(purchase.product_review).to be_alive
    end
  end

  describe "#allows_review_to_be_counted? & .allowing_reviews_to_be_counted & #allows_review?", :vcr do
    before do
      @non_matching_purchases = [
        create(:test_purchase),
        create(:preorder_authorization_purchase),
        create(:failed_purchase),
        create(:refunded_purchase),
        create(:free_purchase, is_access_revoked: true),
        create(:disputed_purchase),
        create(:purchase_in_progress),
        create(:disputed_purchase),
        create(:purchase, is_gift_sender_purchase: true),
        create(:purchase, should_exclude_product_review: true),
        create(:purchase, is_bundle_purchase: true),
        create(:purchase, is_commission_completion_purchase: true)
      ]
      @matching_purchases = [
        create(:purchase),
        create(:purchase, purchase_state: "gift_receiver_purchase_successful", is_gift_receiver_purchase: true),
        create(:free_trial_membership_purchase, should_exclude_product_review: false),
        create(:purchase_2, is_access_revoked: true),
      ]

      true_original_purchase = create(:membership_purchase, is_original_subscription_purchase: true, is_archived_original_subscription_purchase: true)
      @matching_purchases << true_original_purchase
      new_original_purchase = create(:purchase, link: true_original_purchase.link, subscription: true_original_purchase.subscription.reload, is_original_subscription_purchase: true, purchase_state: "not_charged")
      @non_matching_purchases << new_original_purchase
      upgrade_purchase = create(:purchase, link: true_original_purchase.link, subscription: true_original_purchase.subscription, is_upgrade_purchase: true)
      @non_matching_purchases << upgrade_purchase
      @recurring_purchase = create(:purchase, subscription: new_original_purchase.subscription)
    end

    it "is only valid for matching successful or free trial purchases" do
      @non_matching_purchases << @recurring_purchase
      expect(@matching_purchases.all?(&:allows_review_to_be_counted?)).to eq(true)
      expect(@non_matching_purchases.none?(&:allows_review_to_be_counted?)).to eq(true)
      expect(Purchase.allowing_reviews_to_be_counted.load).to match_array(@matching_purchases)
    end

    it "returns true for recurring subscription purchases" do
      @matching_purchases << @recurring_purchase
      expect(@matching_purchases.all?(&:allows_review?)).to eq(true)
    end
  end

  describe "#original_product_review" do
    context "when purchase is for a subscription" do
      let!(:original_purchase) { create(:membership_purchase, is_original_subscription_purchase: true) }
      let!(:recurring_purchase) { original_purchase.subscription.charge! }
      let!(:product_review) { create(:product_review, purchase: original_purchase) }

      it "returns the product review of the original purchase for all purchases in the subscription" do
        expect(original_purchase.reload.original_product_review).to eq(product_review)
        expect(recurring_purchase.reload.original_product_review).to eq(product_review)
      end
    end

    context "when purchase is a gift" do
      let!(:product) { create(:product) }
      let!(:gift) { create(:gift, link: product) }
      let!(:gifter_purchase) { create(:purchase, :gift_sender, link: product, gift_given: gift) }
      let!(:giftee_purchase) { create(:purchase, :gift_receiver, link: product, is_gift_receiver_purchase: true, gift_received: gift) }
      let!(:product_review) { create(:product_review, purchase: giftee_purchase) }

      it "returns giftee's product review for either purchases" do
        expect(giftee_purchase.original_product_review).to eq(product_review)
        expect(gifter_purchase.original_product_review).to eq(product_review)
      end
    end
  end
end
