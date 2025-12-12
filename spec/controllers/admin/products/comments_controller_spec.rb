# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "shared_examples/admin_commentable_concern"

describe Admin::Products::CommentsController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:product) { create(:product) }

  it_behaves_like "Admin::Commentable" do
    let(:commentable_object) { product }
    let(:route_params) { { product_id: product.id } }
  end
end
