# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe CommentsController do
  include ManageSubscriptionHelpers

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:user) { create(:user) }

  shared_examples_for "erroneous index request" do
    it "responds with an error" do
      get(:index, xhr: true, params:)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["success"]).to eq false
      expect(response.parsed_body["error"]).to eq "Not found"
    end
  end

  shared_examples_for "erroneous create request" do
    it "responds with an error without persisting any changes" do
      expect do
        post(:create, xhr: true, params:)
      end.to_not change { product_post.present? ? product_post.comments.count : Comment.count }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["success"]).to eq false
      expect(response.parsed_body["error"]).to eq "Not found"
    end
  end

  shared_examples_for "erroneous destroy request" do
    it "responds with an error" do
      expect do
        delete(:destroy, xhr: true, params:)
      end.to_not change { comment }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["success"]).to eq false
      expect(response.parsed_body["error"]).to eq "Not found"
    end
  end

  shared_examples_for "erroneous update request" do
    it "responds with not found error" do
      expect do
        put(:update, xhr: true, params:)
      end.to_not change { comment.reload }

      expect(response).to have_http_status(http_status)
      expect(response.parsed_body["success"]).to eq false
      expect(response.parsed_body["error"]).to eq error_message
    end
  end

  shared_examples_for "not_found update request" do |http_status, error|
    it_behaves_like "erroneous update request" do
      let(:http_status) { :not_found }
      let(:error_message) { "Not found" }
    end
  end

  shared_examples_for "unauthorized update request" do |http_status, error|
    it_behaves_like "erroneous update request" do
      let(:http_status) { :unauthorized }
    end
  end

  describe "GET index" do
    let(:post) { create(:published_installment, link: product, installment_type: Installment::AUDIENCE_TYPE, shown_on_profile: true) }
    let!(:comment1) { create(:comment, commentable: post, author: user, created_at: 1.minute.ago) }
    let!(:comment2) { create(:comment, commentable: post) }
    let!(:comment_on_another_post) { create(:comment) }

    before do
      stub_const("PaginatedCommentsPresenter::COMMENTS_PER_PAGE", 1)
    end

    context "when user is signed in" do
      before do
        sign_in user
      end

      context "when post exists" do
        let(:params) { { post_id: post.external_id } }

        # TODO: investigate how to make this work. CommentContext new object from controller doesn't match the object
        # instantiated below, so the spec fails
        # TODO :once figured out, add a spec for all other controller actions
        # it_behaves_like "authorize called for action", :get, :index do
        #   let(:record) do
        #     CommentContext.new(
        #       comment: nil,
        #       commentable: post,
        #       purchase: nil
        #     )
        #   end
        #   let(:request_params) { params }
        # end

        it "returns paginated comments with pagination metadata" do
          get(:index, xhr: true, params:)

          expect(response).to have_http_status(:ok)

          result = response.parsed_body
          expect(result["comments"].length).to eq(1)
          expect(result["comments"].first["id"]).to eq(comment1.external_id)
          expect(result["pagination"]).to eq("count" => 2, "items" => 1, "pages" => 2, "page" => 1, "next" => 2, "prev" => nil, "last" => 2)
        end

        context "when 'page' query parameter is specified" do
          let(:params) { { post_id: post.external_id, page: 2 } }

          it "returns paginated comments for the specified page number with pagination metadata" do
            get(:index, xhr: true, params:)

            result = response.parsed_body
            expect(result["comments"].length).to eq(1)
            expect(result["comments"].first["id"]).to eq(comment2.external_id)
            expect(result["pagination"]).to eq("count" => 2, "items" => 1, "pages" => 2, "page" => 2, "next" => nil, "prev" => 1, "last" => 2)
          end
        end

        context "when the specified 'page' option is an overflowing page number" do
          let(:params) { { post_id: post.external_id, page: 3 } }

          it "raises an exception" do
            expect do
              get :index, xhr: true, params:
            end.to raise_error(Pagy::OverflowError)
          end
        end

        context "when post belongs to user's purchased product" do
          let!(:purchase) { create(:purchase, link: product, purchaser: user, created_at: 1.second.ago) }
          let(:post) { create(:published_installment, link: product, shown_on_profile: true) }

          it "returns paginated comments with pagination metadata" do
            get(:index, xhr: true, params:)

            expect(response).to have_http_status(:ok)

            result = response.parsed_body
            expect(result["comments"].length).to eq(1)
            expect(result["comments"].first["id"]).to eq(comment1.external_id)
            expect(result["pagination"]).to eq("count" => 2, "items" => 1, "pages" => 2, "page" => 1, "next" => 2, "prev" => nil, "last" => 2)
          end
        end

        context "when post is not published" do
          let(:post) { create(:installment, link: product, installment_type: "product", published_at: nil) }

          it_behaves_like "erroneous index request"
        end
      end

      context "when post does not exist" do
        let(:params) { { post_id: 1234 } }

        it_behaves_like "erroneous index request"
      end
    end

    context "when user is not signed in" do
      let(:post) { create(:published_installment, link: product, installment_type: "product", shown_on_profile: true) }
      let(:params) { { post_id: post.external_id } }

      it "responds with an error" do
        get(:index, xhr: true, params:)

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body["success"]).to eq false
        expect(response.parsed_body["error"]).to eq "You are not allowed to perform this action."
      end

      context "when the post is visible to everyone" do
        let(:post) { create(:published_installment, link: product, installment_type: Installment::AUDIENCE_TYPE, shown_on_profile: true) }

        let(:params) { { post_id: post.external_id } }

        it "returns paginated comments with pagination metadata" do
          get(:index, xhr: true, params:)

          expect(response).to have_http_status(:ok)

          result = response.parsed_body
          expect(result["comments"].length).to eq(1)
          expect(result["comments"].first["id"]).to eq(comment1.external_id)
          expect(result["pagination"]).to eq("count" => 2, "items" => 1, "pages" => 2, "page" => 1, "next" => 2, "prev" => nil, "last" => 2)
        end
      end

      context "when 'purchase_id' query parameter is specified that matches the id of the purchase of the post's product" do
        let!(:purchase) { create(:purchase, link: product, created_at: 1.second.ago) }
        let(:post) { create(:published_installment, link: product, shown_on_profile: true) }
        let(:params) { { post_id: post.external_id, purchase_id: purchase.external_id } }

        it "returns paginated comments with pagination metadata" do
          get(:index, xhr: true, params:)

          expect(response).to have_http_status(:ok)

          result = response.parsed_body
          expect(result["comments"].length).to eq(1)
          expect(result["comments"].first["id"]).to eq(comment1.external_id)
          expect(result["pagination"]).to eq("count" => 2, "items" => 1, "pages" => 2, "page" => 1, "next" => 2, "prev" => nil, "last" => 2)
        end
      end
    end
  end

  describe "POST create" do
    shared_examples_for "creates a comment" do
      it "adds a comment to the post with the specified content" do
        expect do
          post(:create, xhr: true, params:)
        end.to change { product_post.comments.count }.by(1)

        comment = product_post.comments.first
        expect(comment.content).to eq("Good article!")
        expect(comment.commentable).to eq(product_post)
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_USER_SUBMITTED)
        expect(comment.author_id).to eq(author.id)
        expect(comment.purchase).to be_nil
      end
    end

    context "when user is signed in" do
      before do
        sign_in user
      end

      context "when post exists" do
        let(:product_post) { create(:published_installment, link: product, installment_type: Installment::AUDIENCE_TYPE, shown_on_profile: true) }
        let(:params) { { post_id: product_post.external_id, comment: { content: "Good article!" } } }

        include_examples "creates a comment" do
          let(:author) { user }
        end

        context "when post belongs to user's purchased product" do
          let!(:purchase) { create(:purchase, link: product, purchaser: user, created_at: 1.second.ago) }
          let(:product_post) { create(:published_installment, link: product, shown_on_profile: true) }
          let(:params) { { post_id: product_post.external_id, comment: { content: "Good article!" } } }

          it "adds a comment and persists the id of the purchase along with the comment" do
            expect do
              post(:create, xhr: true, params:)
            end.to change { product_post.comments.count }.by(1)

            comment = product_post.comments.first
            expect(comment.content).to eq("Good article!")
            expect(comment.parent_id).to be_nil
            expect(comment.purchase).to eq(purchase)
          end

          context "when 'parent_id' is specified" do
            let!(:parent_comment) { create(:comment, commentable: product_post) }

            it "adds a reply comment with the id of the parent comment" do
              expect do
                post :create, xhr: true, params: { post_id: product_post.external_id, comment: { content: "Good article!", parent_id: parent_comment.external_id } }
              end.to change { product_post.comments.count }.by(1)

              expect(response).to have_http_status(:ok)

              reply = product_post.comments.last
              expect(reply.parent_id).to eq(parent_comment.id)
            end
          end
        end

        it "does not allow adding a comment with an adult keyword" do
          expect do
            post :create, xhr: true, params: { post_id: product_post.external_id, comment: { content: "nsfw comment" } }
          end.to_not change { product_post.comments.count }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["error"]).to eq("Adult keywords are not allowed")
        end

        context "when post is not published" do
          let(:product_post) { create(:installment, link: product, installment_type: "product", published_at: nil) }

          it_behaves_like "erroneous create request"
        end
      end

      context "when post does not exist" do
        let(:params) { { post_id: 1234, comment: { content: "Good article!" } } }
        let(:product_post) { nil }

        it_behaves_like "erroneous create request"
      end
    end

    context "when seller is signed in" do
      let(:product_post) { create(:published_installment, link: product, installment_type: Installment::AUDIENCE_TYPE) }
      let(:params) { { post_id: product_post.external_id, comment: { content: "Good article!" } } }

      before do
        sign_in seller
      end

      include_examples "creates a comment" do
        let(:author) { seller }
      end
    end

    context "with user signed in as admin for seller" do
      include_context "with user signed in as admin for seller"

      let(:product_post) { create(:published_installment, link: product, installment_type: Installment::AUDIENCE_TYPE) }
      let(:params) { { post_id: product_post.external_id, comment: { content: "Good article!" } } }

      include_examples "creates a comment" do
        let(:author) { user_with_role_for_seller }
      end
    end

    context "when user is not signed in" do
      let(:product_post) { create(:published_installment, link: product, installment_type: "product", shown_on_profile: true) }
      let(:params) { { post_id: product_post.external_id, comment: { content: "Good article!" } } }

      it "responds with an error" do
        post(:create, xhr: true, params:)
        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body["success"]).to eq false
        expect(response.parsed_body["error"]).to eq "You are not allowed to perform this action."
      end

      context "when 'purchase_id' query parameter is specified that matches the id of the purchase of the post's product" do
        let(:purchase) { create(:purchase, link: product, full_name: "Jane Doe", created_at: 1.second.ago) }
        let(:product_post) { create(:published_installment, link: product, shown_on_profile: true) }
        let(:params) { { post_id: product_post.external_id, comment: { content: "Good article!" }, purchase_id: purchase.external_id } }

        it "adds a comment and persists the id of the purchase along with the comment" do
          expect do
            post(:create, xhr: true, params:)
          end.to change { product_post.comments.count }.by(1)

          comment = product_post.comments.first
          expect(comment.content).to eq("Good article!")
          expect(comment.author_id).to be_nil
          expect(comment.author_name).to eq("Jane Doe")
          expect(comment.purchase).to eq(purchase)
        end
      end
    end
  end

  describe "DELETE destroy" do
    let(:post1) { create(:published_installment, link: product, installment_type: "product", shown_on_profile: true) }
    let(:post2) { create(:published_installment, link: create(:product), installment_type: "product", shown_on_profile: true) }
    let(:post1_author) { seller }
    let(:post2_author) { post2.seller }
    let!(:post1_comment1) { create(:comment, commentable: post1, author: user) }
    let!(:post1_comment2) { create(:comment, commentable: post1) }
    let!(:post2_comment) { create(:comment, commentable: post2, author: user) }

    context "when user is not signed in" do
      let(:comment) { post1_comment1 }
      let(:params) { { post_id: post1.external_id, id: comment.external_id } }

      it "responds with an error" do
        expect do
          delete(:destroy, xhr: true, params:)
        end.to_not change { comment.reload.alive? }.from(true)

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body["success"]).to eq false
        expect(response.parsed_body["error"]).to eq "You are not allowed to perform this action."
      end

      context "when 'purchase_id' query parameter is specified that matches the comment's associated purchase" do
        let(:purchase) { create(:purchase, link: product, created_at: 1.second.ago) }
        let(:product_post) { create(:published_installment, link: product, shown_on_profile: true) }
        let!(:comment) { create(:comment, commentable: product_post, purchase:) }
        let(:params) { { post_id: product_post.external_id, id: comment.external_id, purchase_id: purchase.external_id } }

        it "deletes the comment" do
          expect do
            delete(:destroy, xhr: true, params:)
          end.to change { comment.reload.alive? }.from(true).to(false)
            .and change { product_post.comments.alive.count }.by(-1)

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to eq true
        end
      end
    end

    context "when commenter is signed in" do
      before do
        sign_in user
      end

      context "when commenter tries to delete own comment on the specified post" do
        let(:comment) { post1_comment1 }
        let(:params) { { post_id: post1.external_id, id: comment.external_id } }

        it "soft deletes commenter's comment" do
          expect do
            delete(:destroy, xhr: true, params:)
          end.to change { comment.reload.alive? }.from(true).to(false)
            .and change { post1.comments.alive.count }.by(-1)

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to eq true
        end

        context "when a comment has replies" do
          let!(:reply1) { create(:comment, commentable: post1, parent: comment, author: user) }
          let!(:reply_to_reply1) { create(:comment, commentable: post1, parent: reply1) }
          let!(:reply2) { create(:comment, commentable: post1, parent: comment) }

          it "soft deletes the comment along with its replies" do
            expect do
              expect do
                expect do
                  delete :destroy, xhr: true, params: { post_id: post1.external_id, id: reply1.external_id }
                end.to change { reply1.reload.alive? }.from(true).to(false)
                .and change { reply_to_reply1.reload.alive? }.from(true).to(false)
              end.to_not change { comment.reload.alive? }
            end.to_not change { reply2.reload.alive? }

            expect(response).to have_http_status(:ok)
            expect(response.parsed_body["success"]).to eq true
          end
        end
      end

      context "when commenter tries to delete someone else's comment" do
        let(:comment) { post1_comment2 }
        let(:params) { { post_id: post1.external_id, id: comment.external_id } }

        it "responds with an error" do
          expect do
            delete(:destroy, xhr: true, params:)
          end.to_not change { comment.reload.alive? }.from(true)

          expect(response).to have_http_status(:unauthorized)
          expect(response.parsed_body["success"]).to eq false
          expect(response.parsed_body["error"]).to eq "You are not allowed to perform this action."
        end
      end

      context "when commenter tries to delete own comment that does not belong to specified post" do
        let(:comment) { post2_comment }
        let(:params) { { post_id: post1.external_id, id: comment.external_id } }

        it_behaves_like "erroneous destroy request"
      end
    end

    shared_examples_for "destroy as seller or team member" do
      context "when seller tries to delete a comment on own post" do
        let(:comment) { post1_comment1 }
        let(:params) { { post_id: post1.external_id, id: comment.external_id } }

        it "soft deletes the comment" do
          expect do
            delete(:destroy, xhr: true, params:)
          end.to change { comment.reload.alive? }.from(true).to(false)
            .and change { post1.comments.alive.count }.by(-1)

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to eq true
        end
      end

      context "when seller tries to delete a comment on someone else's post" do
        let(:comment) { post2_comment }
        let(:params) { { post_id: post2.external_id, id: comment.external_id } }

        it "responds with an error" do
          expect do
            delete(:destroy, xhr: true, params:)
          end.to_not change { comment.reload.alive? }.from(true)

          expect(response).to have_http_status(:unauthorized)
          expect(response.parsed_body["success"]).to eq false
          expect(response.parsed_body["error"]).to eq error_message
        end
      end
    end

    context "when seller is signed in" do
      before do
        sign_in seller
      end

      include_examples "destroy as seller or team member" do
        let(:error_message) { "You are not allowed to perform this action." }
      end
    end

    context "with user signed in as admin for seller" do
      include_context "with user signed in as admin for seller"

      include_examples "destroy as seller or team member" do
        let(:error_message) { "Your current role as Admin cannot perform this action." }
      end
    end
  end

  describe "PUT update" do
    let(:post1) { create(:published_installment, link: product, installment_type: "product", shown_on_profile: true) }
    let(:post2) { create(:published_installment, link: create(:product), installment_type: "product", shown_on_profile: true) }
    let(:post1_author) { seller }
    let(:post2_author) { post2.seller }
    let!(:post1_comment1) { create(:comment, commentable: post1, author: user) }
    let!(:post1_comment2) { create(:comment, commentable: post1) }
    let!(:post2_comment) { create(:comment, commentable: post2, author: user) }

    context "when user is not signed in" do
      let(:comment) { post1_comment1 }
      let(:params) { { post_id: post1.external_id, id: comment.external_id, comment: { content: "Nice article" } } }

      it "responds with an error" do
        expect do
          put(:update, xhr: true, params:)
        end.to_not change { comment.reload }

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body["success"]).to eq false
        expect(response.parsed_body["error"]).to eq "You are not allowed to perform this action."
      end

      context "when 'purchase_id' query parameter is specified that matches the comment's associated purchase" do
        let(:purchase) { create(:purchase, link: product, created_at: 1.second.ago) }
        let(:product_post) { create(:published_installment, link: product, shown_on_profile: true) }
        let!(:comment) { create(:comment, commentable: product_post, purchase:) }
        let(:params) { { post_id: product_post.external_id, id: comment.external_id, purchase_id: purchase.external_id, comment: { content: "Nice article" } } }

        it "updates the comment" do
          expect do
            put(:update, xhr: true, params:)
          end.to change { comment.reload.content }.to("Nice article")

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to eq true
          expect(response.parsed_body["comment"]["content"]["original"]).to eq("Nice article")
        end
      end

      context "when post belongs to user's purchased recurring subscription whose plan changes", :vcr do
        before(:each) do
          setup_subscription

          @product_post = create(:published_installment, link: @product)
          @comment = create(:comment, commentable: @product_post, purchase: @original_purchase)

          @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)

          @new_original_purchase = @subscription.reload.original_purchase
        end

        context "when 'purchase_id' query parameter matches the updated 'original_purchase'" do
          it "updates the comment" do
            expect do
              put :update, xhr: true, params: { post_id: @product_post.external_id, id: @comment.external_id, purchase_id: @new_original_purchase.external_id, comment: { content: "Nice article" } }
            end.to change { @comment.reload.content }.to("Nice article")

            expect(response).to have_http_status(:ok)
            expect(response.parsed_body["comment"]["content"]["original"]).to eq("Nice article")
          end
        end

        context "when 'purchase_id' query parameter matches the  archived 'original_purchase' and does not match the updated 'original_purchase'" do
          it "updates the comment" do
            expect do
              put :update, xhr: true, params: { post_id: @product_post.external_id, id: @comment.external_id, purchase_id: @original_purchase.external_id, comment: { content: "Nice article" } }
            end.to change { @comment.reload.content }.to("Nice article")

            expect(response).to have_http_status(:ok)
            expect(response.parsed_body["comment"]["content"]["original"]).to eq("Nice article")
          end
        end
      end
    end

    context "when commenter is signed in" do
      before do
        sign_in user
      end

      context "when commenter tries to update own comment on the specified post" do
        let(:comment) { post1_comment1 }
        let(:params) { { post_id: post1.external_id, id: comment.external_id, comment: { content: "Nice\t\t\t\tarticle!!!\n\n\n\n\tKeep it up.   <script>evil</script>" } } }

        it "updates commenter's comment" do
          expect do
            put(:update, xhr: true, params:)
          end.to change { comment.reload.content }.to("Nice\t\t\t\tarticle!!!\n\n\tKeep it up.   <script>evil</script>")

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to eq true
          expect(response.parsed_body["comment"]["content"]["original"]).to eq("Nice\t\t\t\tarticle!!!\n\n\tKeep it up.   <script>evil</script>")
          expect(response.parsed_body["comment"]["content"]["formatted"]).to eq("Nice\t\t\t\tarticle!!!\n\n\tKeep it up.   &lt;script&gt;evil&lt;/script&gt;")
        end

        it "does not allow updating the comment with an adult keyword" do
          expect do
            put :update, xhr: true, params: { post_id: post1.external_id, id: comment.external_id, comment: { content: "nsfw comment" } }
          end.to_not change { comment.reload.content }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["error"]).to eq("Adult keywords are not allowed")
        end
      end

      context "when commenter tries to update someone else's comment" do
        let(:comment) { post1_comment2 }
        let(:params) { { post_id: post1.external_id, id: comment.external_id, comment: { content: "Nice article" } } }

        it_behaves_like "unauthorized update request" do
          let(:error_message) { "You are not allowed to perform this action." }
        end
      end

      context "when commenter tries to update own comment that does not belong to specified post" do
        let(:comment) { post2_comment }
        let(:params) { { post_id: post1.external_id, id: comment.external_id, comment: { content: "Nice article" } } }

        it_behaves_like "not_found update request"
      end
    end

    context "with seller signed in" do
      before do
        sign_in seller
      end

      context "when seller tries to update a user's comment on own post" do
        let(:comment) { post1_comment1 }
        let(:params) { { post_id: post1.external_id, id: comment.external_id, comment: { content: "Nice article" } } }

        it_behaves_like "unauthorized update request" do
          let(:error_message) { "You are not allowed to perform this action." }
        end
      end

      context "when seller tries to update own comment on own post" do
        let(:comment) { create(:comment, commentable: post1, author: seller) }
        let(:params) { { post_id: post1.external_id, id: comment.external_id, comment: { content: "Nice article" } } }

        it "updates the comment" do
          expect do
            put(:update, xhr: true, params:)
          end.to change { comment.reload.content }.to("Nice article")

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to eq true
          expect(response.parsed_body["comment"]["content"]["original"]).to eq("Nice article")
        end
      end
    end

    context "with user signed in as admin for seller" do
      include_context "with user signed in as admin for seller"

      context "when trying to update a user's comment on seller post" do
        let(:comment) { post1_comment1 }
        let(:params) { { post_id: post1.external_id, id: comment.external_id, comment: { content: "Nice article" } } }

        it_behaves_like "unauthorized update request" do
          let(:error_message) { "Your current role as Admin cannot perform this action." }
        end
      end

      context "when trying to update seller's comment on seller post" do
        let(:comment) { create(:comment, commentable: post1, author: seller) }
        let(:params) { { post_id: post1.external_id, id: comment.external_id, comment: { content: "Nice article" } } }

        it_behaves_like "unauthorized update request" do
          let(:error_message) { "Your current role as Admin cannot perform this action." }
        end
      end
    end
  end
end
