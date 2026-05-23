# frozen_string_literal: true

require "test_helper"
require "shared_examples/admin_base_controller_concern"
require "shared_examples/admin_commentable_concern"

class AdminProductsCommentsControllerTest < ActionController::TestCase
  self.described_class = Admin::Products::CommentsController
  tests Admin::Products::CommentsController



  context_ Admin::Products::CommentsController do
    it_behaves_like "inherits from Admin::BaseController"

    let(:product) { create(:product) }

    it_behaves_like "Admin::Commentable" do
      let(:commentable_object) { product }
      let(:route_params) { { product_external_id: product.external_id } }
    end
  end
end
