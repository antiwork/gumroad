# frozen_string_literal: true

require "spec_helper"

# Same object as config.action_dispatch.default_headers: Response captures that hash
# before initializers run (rails/rails#58145), so SecureHeaders' in-place deletes only
# reach responses if the assignment lives in application.rb, not an initializer.
describe "Rails default_headers wiring" do
  let(:config_headers) { Rails.application.config.action_dispatch.default_headers }

  it "shares one hash between the app config and ActionDispatch::Response" do
    expect(config_headers).to be(ActionDispatch::Response.default_headers)
  end

  it "lets SecureHeaders empty the framing headers out of that shared hash" do
    expect(config_headers["X-Frame-Options"]).to be_nil
    expect(config_headers["Referrer-Policy"]).to be_nil
    expect(config_headers["X-Download-Options"]).to be_nil
    # nosniff still reaches responses: SecureHeaders' middleware sets it, not this hash.
    expect(config_headers["X-Content-Type-Options"]).to be_nil
  end
end
