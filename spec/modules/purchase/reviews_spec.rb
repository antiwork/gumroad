# frozen_string_literal: true

require "spec_helper"

describe Purchase::Reviews do
  describe "#post_review" do
    context "non-recurring purchase" do
      let!(:purchase) { create(:purchase) }

      context "when there is an existing product_review" do
        let!(:existing_product_review) { create(:product_review, purchase:, rating: 1, message: "Original message") }

        it "updates the existing product_review with the provided rating" do
          result = purchase.post_review(rating: 1, message: "Updated message")

          expect(result).to eq(existing_product_review)
          expect(result.rating).to eq(1)
          expect(result.message).to eq("Updated message")
        end

        it "does not update the rating if the purchase does not allow reviews to be counted" do
          purchase.update!(stripe_refunded: true)

          expect { purchase.post_review(rating: 5, message: "Updated message") }.to raise_error(ProductReview::RestrictedOperationError)

          expect(existing_product_review.reload.rating).to eq(1)
          expect(existing_product_review.message).to eq("Original message")
        end
      end

      context "when there is no existing product_review" do
        it "creates a new product review for a purchase that allows reviews to be counted" do
          expect(purchase.product_review).to be(nil)

          result = purchase.post_review(rating: 1, message: "Updated message")

          expect(result).to be_a(ProductReview)
          expect(result.rating).to eq(1)
          expect(result.message).to eq("Updated message")
          expect(result.purchase).to eq(purchase)
        end

        it "creates a product review and enqueues an email notification" do
          expect(purchase.product_review).to be(nil)

          expect do
            purchase.post_review(rating: 1, message: "Updated message")
          end.to have_enqueued_mail(ContactingCreatorMailer, :review_submitted).with { purchase.reload.product_review.id }

          expect(purchase.reload.product_review).not_to be(nil)
          expect(purchase.product_review.rating).to eq(1)
          expect(purchase.product_review.message).to eq("Updated message")
        end

        it "does not enqueue an email when review notifications are disabled" do
          purchase.seller.update(disable_reviews_email: true)

          expect do
            purchase.post_review(rating: 1, message: "Updated message")
          end.to_not have_enqueued_mail(ContactingCreatorMailer, :review_submitted)
        end

        it "does not add review when the purchase does not allow reviews to be counted" do
          allow(purchase).to receive(:allows_review_to_be_counted?).and_return(false)

          expect { purchase.post_review(rating: 1, message: "Updated message") }.to raise_error(ProductReview::RestrictedOperationError)

          expect(purchase.reload.product_review).to be_blank
        end

        it "saves the link_id associated with the purchase on the product review" do
          review = purchase.post_review(rating: 1, message: "Updated message")

          expect(review.link_id).to eq(purchase.link_id)
        end
      end
    end

    context "recurring purchase" do
      let!(:subscription_product) { create(:subscription_product) }
      let!(:subscription) { create(:subscription, link: subscription_product) }
      let!(:original_purchase) { create(:purchase, link: subscription_product, is_original_subscription_purchase: true, subscription:) }
      let!(:recurring_purchase) { create(:purchase, link: subscription_product, subscription:) }

      before { recurring_purchase.reload }

      context "when there is an existing product_review" do
        let!(:product_review) { create(:product_review, rating: 1, purchase: original_purchase) }

        it "updates the product review of the original purchase in case of recurring purchase of a subscription" do
          result = recurring_purchase.post_review(rating: 1)

          expect(result).to eq(product_review)
          original_purchase.reload
          expect(original_purchase.product_review.rating).to eq(1)
          expect(original_purchase.product_review.message).to be_nil
        end
      end

      context "when there is no existing product_review" do
        it "adds product review to the original purchase in case of recurring purchase of a subscription" do
          review = recurring_purchase.post_review(rating: 1)

          expect(review.purchase).to eq(original_purchase)
          expect(original_purchase.reload.product_review.rating).to eq(1)
        end
      end
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
      purchase.post_review(rating: 3)

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
      purchase.post_review(rating: 3)
      expect(product.average_rating).to eq(3)

      purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents), purchase.seller.id)
      expect(product.average_rating).to eq(0)
      expect(purchase.product_review).to be_deleted
    end

    it "removes reviews from all products in a bundle when bundle is refunded" do
      bundle_purchase = create(:purchase, link: create(:product, :bundle))
      bundle_purchase.create_artifacts_and_send_receipt!

      bundle_purchase.product_purchases.each do |product_purchase|
        product_purchase.post_review(rating: 1, message: "test review")
        expect(product_purchase.link.average_rating).to eq(1)
        expect(product_purchase.product_review).to be_present
        expect(product_purchase.product_review).to be_alive
        expect(product_purchase.link.reviews_count).to eq(1)
        expect(product_purchase.link.average_rating).to eq(1)
      end

      bundle_purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, bundle_purchase.total_transaction_cents), bundle_purchase.seller.id)

      bundle_purchase.product_purchases.each do |product_purchase|
        expect(product_purchase.reload.stripe_refunded).to eq(true)
        expect(product_purchase.product_review.reload).to be_deleted
        expect(product_purchase.link.reviews_count).to eq(0)
        expect(product_purchase.link.average_rating).to eq(0)
      end
    end
  end

  describe "revoking/unrevoking access" do
    it "updates the product review" do
      purchase = create(:purchase, price_cents: 0)
      product = purchase.link

      expect(product.average_rating).to eq(0)
      purchase.post_review(rating: 3)
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
