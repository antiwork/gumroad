# frozen_string_literal: true

require "spec_helper"

describe AdminActionTracker do
  controller do
    include AdminActionTracker
    def index
      head :ok
    end
  end

  before do
    routes.draw { get :index, to: "anonymous#index" }
  end

  it "calling an action increments the call_count" do
    record = create(:admin_action_call_info, controller_name: "AnonymousController", action_name: "index")

    get :index
    expect(record.reload.call_count).to eq(1)
  end
end
