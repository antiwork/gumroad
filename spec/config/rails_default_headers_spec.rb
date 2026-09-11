# frozen_string_literal: true

require "spec_helper"

# config/application.rb assigns action_dispatch.default_headers instead of an initializer
# because since Rails 8.0.5 the action_controller.live_streaming_excluded_keys initializer
# loads ActionDispatch::Response before config/initializers run, so the response class
# captures the hash early (rails/rails#58145). SecureHeaders then deletes its conflicting
# keys from that hash in place, which only reaches the response if both sides are the same
# object. Move the assignment back into an initializer and Rails starts emitting its own
# X-Frame-Options again, which is what stops sellers framing product pages.
describe "Rails default_headers wiring" do
  let(:config_headers) { Rails.application.config.action_dispatch.default_headers }

  it "shares one hash between the app config and ActionDispatch::Response" do
    expect(config_headers).to be(ActionDispatch::Response.default_headers)
  end

  it "lets SecureHeaders empty the framing headers out of that shared hash" do
    expect(config_headers["X-Frame-Options"]).to be_nil
    expect(config_headers["Referrer-Policy"]).to be_nil
    expect(config_headers["X-Download-Options"]).to be_nil
  end
end
