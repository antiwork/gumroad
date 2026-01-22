# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "shared_examples/admin_commentable_concern"

describe Admin::Purchases::CommentsController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:purchase) { create(:purchase) }

  it_behaves_like "Admin::Commentable" do
    let(:commentable_object) { purchase }
    let(:route_params) { { purchase_external_id: purchase.external_id } }
  end
end
