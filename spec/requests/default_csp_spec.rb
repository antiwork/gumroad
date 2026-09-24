# frozen_string_literal: true

require "spec_helper"

# The initializer spec reads the configuration object; this pins the header a browser
# actually receives, which is where a directive silently dropping out of the
# middleware stack would show up.
describe "default Content-Security-Policy response header", type: :request do
  it "serves the tightened plugin, base-uri, child and worker directives" do
    get "/login", headers: { "HOST" => VALID_REQUEST_HOSTS.first }

    expect(response).to be_successful
    csp = response.headers["Content-Security-Policy"]
    expect(csp).to include("object-src 'none'")
    expect(csp).to include("base-uri 'self'")
    expect(csp).to include("child-src 'self' blob:")
    expect(csp).to include("worker-src 'self' blob:")
    expect(csp).not_to include("object-src *")
    expect(csp).not_to include("worker-src *")
  end
end
