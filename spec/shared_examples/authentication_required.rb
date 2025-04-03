# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "authentication required for action" do |verb, action|
  before do
    sign_out(User.last)
  end

  it "redirects to the login page" do
    public_send(verb, action, params: defined?(request_params) ? request_params : {})

    expect(response).to be_a_redirect
    # Do a match as response.location contains `next` query string params
    expect(response.location).to match(login_url)
  end
end
