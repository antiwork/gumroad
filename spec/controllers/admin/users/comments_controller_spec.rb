# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "shared_examples/admin_commentable_concern"

describe Admin::Users::CommentsController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:user) { create(:user) }

  it_behaves_like "Admin::Commentable" do
    let(:commentable_object) { user }
    let(:route_params) { { user_id: user.id } }
  end
end
