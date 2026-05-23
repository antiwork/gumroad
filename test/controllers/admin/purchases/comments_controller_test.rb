# frozen_string_literal: true

require "test_helper"
require "shared_examples/admin_base_controller_concern"
require "shared_examples/admin_commentable_concern"

class AdminPurchasesCommentsControllerTest < ActionController::TestCase
  self.described_class = Admin::Purchases::CommentsController
  tests Admin::Purchases::CommentsController



  context_ Admin::Purchases::CommentsController do
    it_behaves_like "inherits from Admin::BaseController"

    let(:purchase) { create(:purchase) }

    it_behaves_like "Admin::Commentable" do
      let(:commentable_object) { purchase }
      let(:route_params) { { purchase_external_id: purchase.external_id } }
    end
  end
end
