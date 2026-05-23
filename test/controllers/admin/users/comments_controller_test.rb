# frozen_string_literal: true

require "test_helper"
require "shared_examples/admin_base_controller_concern"
require "shared_examples/admin_commentable_concern"

class AdminUsersCommentsControllerTest < ActionController::TestCase
  self.described_class = Admin::Users::CommentsController
  tests Admin::Users::CommentsController



  context_ Admin::Users::CommentsController do
    it_behaves_like "inherits from Admin::BaseController"

    let(:user) { create(:user) }

    it_behaves_like "Admin::Commentable" do
      let(:commentable_object) { user }
      let(:route_params) { { user_external_id: user.external_id } }
    end
  end
end
