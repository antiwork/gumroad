# frozen_string_literal: true

require "spec_helper"

# secure_headers < 7.2 rejoined the cookies into one newline-separated string (the
# Rack 2 shape). Rack::MiniProfiler then promoted that blob to a single array entry,
# and Puma drops any entry containing a newline — losing guid, CSRF and session at once.
describe "Set-Cookie response header", type: :request do
  it "carries one entry per cookie with no embedded newlines" do
    host! DOMAIN

    get root_path

    set_cookie = response.headers["set-cookie"]
    expect(set_cookie).to be_an(Array)
    expect(set_cookie.size).to be > 1
    expect(set_cookie.grep(/\n/)).to be_empty
  end
end
