# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "Admin::Commentable" do
  let(:admin_user) { create(:admin_user) }
  let(:commentable_object) { raise NotImplementedError, "Define commentable_object in the spec" }
  let(:route_params) { raise NotImplementedError, "Define route_params in the spec" }

  before do
    sign_in admin_user
  end

  describe "GET index" do
    context "when there are comments" do
      let!(:comment1) do
        create(:comment,
               commentable: commentable_object,
               author: admin_user,
               content: "First comment",
               comment_type: "note",
               created_at: 2.days.ago)
      end

      let!(:comment2) do
        create(:comment,
               commentable: commentable_object,
               author: admin_user,
               content: "Second comment",
               comment_type: "note",
               created_at: 1.day.ago)
      end

      let!(:unrelated_comment) do
        create(:comment,
               commentable: create(:user),
               author: admin_user,
               content: "Unrelated comment",
               comment_type: "note",
               created_at: 3.days.ago)
      end

      it "returns all comments in descending order" do
        get :index, params: route_params, format: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body

        expect(json_response["comments"]).to be_an(Array)
        expect(json_response["comments"].length).to eq(2)

        expect(json_response).to eq(
          "comments" => [
            {
              "id" => comment2.id,
              "content" => "Second comment",
              "author" => {
                "id" => admin_user.id,
                "name" => admin_user.name,
                "email" => admin_user.email
              },
              "author_name" => admin_user.username,
              "comment_type" => "note",
              "updated_at" => comment2.updated_at.iso8601
            },
            {
              "id" => comment1.id,
              "content" => "First comment",
              "author" => {
                "id" => admin_user.id,
                "name" => admin_user.name,
                "email" => admin_user.email
              },
              "author_name" => admin_user.username,
              "comment_type" => "note",
              "updated_at" => comment1.updated_at.iso8601
            }
          ]
        )
      end
    end

    it "returns empty array when there are no comments" do
      get :index, params: route_params, format: :json

      expect(response).to have_http_status(:success)
      json_response = response.parsed_body
      expect(json_response["comments"]).to eq([])
    end
  end

  describe "POST create" do
    let(:valid_comment_params) do
      {
        content: "This is a test comment",
        comment_type: Comment::COMMENT_TYPE_FLAGGED
      }
    end

    it "creates a new comment for the commentable" do
      expect do
        post :create, params: route_params.merge(comment: valid_comment_params), format: :json
      end.to change { commentable_object.comments.count }.by(1)

      expect(response).to have_http_status(:success)

      comment = commentable_object.comments.last
      expect(response.parsed_body["success"]).to be true
      expect(response.parsed_body["comment"]).to eq(
        "id" => comment.id,
        "content" => "This is a test comment",
        "author" => {
          "id" => admin_user.id,
          "name" => admin_user.name,
          "email" => admin_user.email
        },
        "author_name" => admin_user.name,
        "comment_type" => "flagged",
        "updated_at" => comment.updated_at.iso8601
      )
    end

    it "associates the comment with the current admin user" do
      post :create, params: route_params.merge(comment: valid_comment_params), format: :json

      comment = commentable_object.comments.last
      expect(comment.author).to eq(admin_user)
    end

    it "returns an error when content is missing" do
      invalid_params = valid_comment_params.merge(content: "")

      expect do
        post :create, params: route_params.merge(comment: invalid_params), format: :json
      end.not_to change { commentable_object.comments.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be false
      expect(response.parsed_body["error"]).to include("can't be blank")
    end

    it "creates a comment with 'note' type when comment_type is not provided" do
      invalid_params = valid_comment_params.except(:comment_type)

      expect do
        post :create, params: route_params.merge(comment: invalid_params), format: :json
      end.to change { commentable_object.comments.count }.by(1)

      expect(response).to have_http_status(:success)
      expect(response.parsed_body["success"]).to be true
      expect(commentable_object.comments.last.comment_type).to eq(Comment::COMMENT_TYPE_NOTE)
    end

    it "returns an error when content is too long" do
      invalid_params = valid_comment_params.merge(content: "a" * 10_001)

      expect do
        post :create, params: route_params.merge(comment: invalid_params), format: :json
      end.not_to change { commentable_object.comments.count }

      expect(response).to have_http_status(:unprocessable_entity)
      json_response = response.parsed_body

      expect(json_response["success"]).to be false
      expect(json_response["error"]).to include("too long")
    end
  end
end
