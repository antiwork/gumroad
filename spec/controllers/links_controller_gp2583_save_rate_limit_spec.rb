# frozen_string_literal: true

require "spec_helper"

# Pins the per-product save rate limit (antiwork/gumroad-private#2583). The row lock
# serializes saves of one product, so a client retrying faster than a save can finish is
# what builds the queue behind it — the attempt rate itself has to be bounded, and bounded
# per product so one product's storm cannot refuse a save of another.
describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:other_product) { create(:product, user: seller) }
  let(:limit) { LinksController::EDITOR_SAVE_RATE_LIMIT }

  before { sign_in seller }

  after do
    $redis.del(RedisKey.editor_save_throttle(product.id), RedisKey.editor_save_throttle(other_product.id))
  end

  def save_product(product)
    patch :update, params: { id: product.unique_permalink, name: product.name }, as: :json
  end

  # Counts the window as already spent up to `count`, so an example reaches the limit
  # without sending the limit's worth of real saves.
  def spend_window(product, count)
    $redis.setex(RedisKey.editor_save_throttle(product.id), LinksController::EDITOR_SAVE_RATE_LIMIT_PERIOD.to_i, count)
  end

  it "admits the save that spends the window's last attempt and refuses the next one" do
    spend_window(product, limit - 1)

    save_product(product)
    expect(response).to have_http_status(:success)

    save_product(product)
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"].to_i).to be > 0
    expect(response.parsed_body["retry_after"]).to be > 0
    # The retryable rate-limit answer, not the row lock's 409: the attempt never reached
    # the lock, so the client must not treat it as a concurrent save to wait out.
    expect(response.parsed_body["error_code"]).to be_nil
  end

  it "counts and refuses per product, leaving another product's saves alone" do
    spend_window(product, limit)

    save_product(other_product)
    expect(response).to have_http_status(:success)
    expect($redis.get(RedisKey.editor_save_throttle(other_product.id))).to eq("1")

    save_product(product)
    expect(response).to have_http_status(:too_many_requests)
  end

  it "admits the save when the counter is unreadable, instead of failing the save with Redis" do
    allow($redis).to receive(:incr).and_raise(Redis::CannotConnectError)

    save_product(product)

    expect(response).to have_http_status(:success)
  end
end
