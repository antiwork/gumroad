# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::CommentsController do
  it_behaves_like "inherits from Admin::BaseController"

  describe "POST create" do
    let(:user) { create(:user) }
    let(:comment_attrs) do
      { content: "comment content", comment_type: "comment", commentable_type: "User", commentable_id: user.id }
    end

    describe "with a signed in admin user" do
      let(:admin_user) { create(:admin_user) }

      before do
        sign_in admin_user
      end

      it "creates the comment with valid params" do
        expect do
          post :create, params: { comment: comment_attrs }
        end.to change { Comment.count }.by(1)
        expect(Comment.last.content).to eq(comment_attrs[:content])
      end

      it "does not create comment with invalid params" do
        expect do
          comment_attrs.delete(:content)
          post :create, params: { comment: comment_attrs }
        end.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    describe "from an external source" do
      it "creates a comment with a valid token" do
        expect do
          post :create, params: { auth_token: GlobalConfig.get("IFFY_TOKEN"), comment: comment_attrs.merge(author_name: "iffy") }
        end.to change { Comment.count }.by(1)
        expect(Comment.last.content).to eq(comment_attrs[:content])
      end

      it "does not create a comment with an invalid token" do
        expect do
          post :create, params: { comment: comment_attrs }
        end.to_not change { Comment.count }
      end
    end
  end
end
