# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe ProductReviewResponsesController do
  describe "PUT update" do
    let!(:seller) { create(:named_seller) }
    let!(:product) { create(:product, user: seller) }
    let!(:purchaser) { create(:user) }
    let!(:purchase) { create(:purchase, link: product, purchaser: purchaser) }
    let!(:product_review) { create(:product_review, purchase: purchase) }

    let(:product_review_for_another_seller) { create(:product_review) }

    before do
      sign_in seller
    end

    it_behaves_like "authorize called for action", :put, :update do
      let(:record) { ProductReviewResponse }
      let(:policy_klass) { ProductReviewResponsePolicy }
      let(:request_params) { { id: purchase.external_id, message: "Response" } }
      let(:request_format) { :json }
    end

    it "creates a new response if there is none" do
      product_review.response&.destroy!

      put :update, params: { id: purchase.external_id, message: "New" }, as: :json

      expect(response).to have_http_status(:no_content)
      product_review.reload
      expect(product_review.response.message).to eq("New")
      expect(product_review.response.user_id).to eq(seller.id)
    end

    it "updates an existing response if there is one, regardless of who the original author is" do
      different_user = create(:user)
      review_response = create(:product_review_response, message: "Old", product_review:, user: different_user)

      put :update, params: { id: purchase.external_id, message: "Updated" }, as: :json

      expect(response).to have_http_status(:no_content)
      review_response.reload
      expect(review_response.product_review).to eq(product_review)
      expect(review_response.message).to eq("Updated")
      expect(review_response.user_id).to eq(seller.id)
    end

    it "allows responding to reviews that do not count towards review stats" do
      purchase.update!(stripe_refunded: true)
      expect(purchase.allows_review_to_be_counted?).to be false

      put :update, params: { id: purchase.external_id, message: "Review response" }, as: :json

      expect(response).to have_http_status(:no_content)
      product_review.reload
      expect(product_review.response.message).to eq("Review response")
      expect(product_review.response.user_id).to eq(seller.id)
    end

    it "returns an error if the message is blank" do
      put :update, params: { id: purchase.external_id, message: "" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Message can't be blank")
    end

    it "404s for non-existent purchase" do
      expect do
        put :update, params: { id: "non_existent_id", message: "Updated" }, as: :json
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end

    it "404s when there is no product review" do
      product_review.delete

      put :update, params: { id: purchase.external_id, message: "Updated" }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "401s when the product review is for another seller" do
      put :update, params: {
        id: product_review_for_another_seller.purchase.external_id,
        message: "Updated",
      }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE destroy" do
    let!(:seller) { create(:named_seller) }
    let!(:product) { create(:product, user: seller) }
    let!(:purchaser) { create(:user) }
    let!(:purchase) { create(:purchase, link: product, purchaser: purchaser) }
    let!(:product_review) { create(:product_review, purchase: purchase) }
    let!(:product_review_response) { create(:product_review_response, product_review: product_review) }

    let(:product_review_for_another_seller) { create(:product_review) }

    before do
      sign_in seller
    end

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { ProductReviewResponse }
      let(:policy_klass) { ProductReviewResponsePolicy }
      let(:request_params) { { id: purchase.external_id } }
      let(:request_format) { :json }
    end

    it "destroys the response" do
      delete :destroy, params: { id: purchase.external_id }, as: :json

      expect(response).to have_http_status(:no_content)
      product_review.reload
      expect(product_review.response).to be_nil
    end

    it "404s for non-existent purchase" do
      expect do
        delete :destroy, params: { id: "non_existent_id" }, as: :json
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end

    it "404s when there is no product review" do
      product_review.delete

      delete :destroy, params: { id: purchase.external_id }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "401s when the product review is for another seller" do
      delete :destroy, params: {
        id: product_review_for_another_seller.purchase.external_id,
      }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
