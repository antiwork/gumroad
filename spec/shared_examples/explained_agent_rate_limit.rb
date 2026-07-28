# frozen_string_literal: true

# The 429 body the agent endpoints render is what the seller reads in the chat, so every throttled
# agent surface (web buffered/streaming, mobile buffered/streaming) is held to the same wording:
# name the real limit, say what counts towards it, say how long is left, and rule out the account
# being at fault. A generic "something went wrong" here is the bug this covers — it sent sellers
# clearing browser data and emailing support over a limit they only had to wait out.
RSpec.shared_examples_for "an explained agent rate limit" do
  it "explains the limit rather than reporting a generic failure" do
    subject

    expect(response).to have_http_status(:too_many_requests)
    # Parsed by hand rather than via `parsed_body`: the streaming controllers respond with an
    # ActionController::LiveTestResponse, which doesn't implement it.
    body = JSON.parse(response.body)
    expect(body["error"]).to include("30 agent requests")
    expect(body["error"]).to include("confirming a change both count")
    expect(body["error"]).to include("nothing is wrong with your account or your store")
    expect(body["error"]).to match(/continue in \d+ minutes?/)
    expect(body["retry_after"]).to be > 0
    expect(response.headers["Retry-After"]).to be_present
  end
end
