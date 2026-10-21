# frozen_string_literal: true

require "spec_helper"
require "timeout"

# A post handoff holds each follow it sends to until the provider answers. An opt-out that can't get the follow in
# time must say so and leave the follow as it was, so the person can try again, rather than fail with a 500.
describe "Opting out while a post is being handed to the provider", type: :request do
  include Devise::Test::IntegrationHelpers

  self.use_transactional_tests = false

  before do
    @seller = create(:named_user)
    @follower = create(:active_follower, user: @seller, email: "opting-out@example.com")
    create(:active_follower, user: @seller, email: "stayer@example.com")
    @requests = Queue.new
    @in_provider = Queue.new
    @release_provider = Queue.new
    endpoint = double("SendGrid mail send")
    allow(endpoint).to receive(:post) do |request_body:|
      @requests << request_body["personalizations"].map { _1["to"][0]["email"] }
      if Thread.current[:hold_provider]
        @in_provider << true
        @release_provider.pop
      end
      double(status_code: 202, body: "")
    end
    allow(SendGrid::API).to receive(:new).and_return(double(client: double(mail: double(_: endpoint))))
    # Only blast threads take the provider branch; the requests below run as usual in test.
    allow(Rails.env).to receive(:test?).and_wrap_original { |original| Thread.current[:provider_branch] ? false : original.call }
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
    stub_const("Follower::OPT_OUT_LOCK_WAIT_SECONDS", 1)
    # The server default would hold the request for 50s; keep this connection's own wait short either way.
    ActiveRecord::Base.connection.execute("SET SESSION innodb_lock_wait_timeout = 3")
  end

  after do
    ActiveRecord::Base.connection.execute("SET SESSION innodb_lock_wait_timeout = DEFAULT")
    post_ids = Installment.where(seller_id: @seller.id).pluck(:id)
    SentPostEmail.where(post_id: post_ids).delete_all
    PostEmailBlast.where(post_id: post_ids).delete_all
    Installment.where(id: post_ids).delete_all
    purchase_ids = Purchase.where(seller_id: @seller.id).pluck(:id)
    UrlRedirect.where(purchase_id: purchase_ids).delete_all
    Purchase.where(id: purchase_ids).delete_all
    product_ids = Link.where(user_id: @seller.id).pluck(:id)
    Link.where(id: product_ids).delete_all
    AudienceMember.where(seller_id: @seller.id).delete_all
    follower_ids = Follower.where(followed_id: @seller.id).pluck(:id)
    PaperTrail::Version.where(item_type: "Follower", item_id: follower_ids).delete_all
    Follower.where(id: follower_ids).delete_all
    @seller.destroy!
    delete_leftovers(user_ids: [@seller.id], product_ids:, installment_ids: post_ids)
  end

  def start_blast(hold_provider:)
    blast = create(:blast, :just_requested, post: create(:follower_post, :published, seller: @seller))
    Thread.new do
      Thread.current[:provider_branch] = true
      Thread.current[:hold_provider] = hold_provider
      ActiveRecord::Base.connection_pool.with_connection { SendPostBlastEmailsJob.new.perform(blast.id) }
    end
  end

  # The page a person who clicked an unsubscribe link sees: what happened, and a link that repeats the same request.
  def expect_retry_page_for(path)
    page = Nokogiri::HTML(response.body)
    expect(response.media_type).to eq("text/html")
    expect(page.at_css("h2")&.text).to eq("We couldn't finish unsubscribing you.")
    expect(page.text).not_to match(/you have been unsubscribed|no longer receive/i)
    retry_link = page.css("a").find { _1.text.strip == "Try again" }
    expect(retry_link&.[]("href")).to eq(path)
    retry_link["href"]
  end

  def requested_addresses
    addresses = []
    addresses.concat(@requests.pop) until @requests.empty?
    addresses.sort
  end

  it "answers the unfollow link with a retryable 503 while the follow is held, keeps the follow, and unfollows on retry" do
    sender = start_blast(hold_provider: true)
    Timeout.timeout(10) { @in_provider.pop }

    expect { get cancel_follow_path(@follower.external_id, format: :json) }.not_to raise_error
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Retry-After"]).to eq("60")
    expect(response.body).to be_empty
    expect(Follower.find(@follower.id)).to be_alive

    @release_provider << true
    sender.value
    expect(requested_addresses).to eq(["opting-out@example.com", "stayer@example.com"])

    get cancel_follow_path(@follower.external_id, format: :json)

    expect(response).to have_http_status(:ok)
    expect(Follower.find(@follower.id)).to be_deleted
    start_blast(hold_provider: false).value
    expect(requested_addresses).to eq(["stayer@example.com"])
  ensure
    @release_provider << true
    sender&.join(10)
  end

  it "shows a person who clicked the unfollow link a page to try again while the follow is held, and unfollows when they do" do
    sender = start_blast(hold_provider: true)
    Timeout.timeout(10) { @in_provider.pop }
    path = cancel_follow_path(@follower.external_id)

    expect { get path }.not_to raise_error
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Retry-After"]).to eq("60")
    expect(Follower.find(@follower.id)).to be_alive
    retry_path = expect_retry_page_for(path)

    @release_provider << true
    sender.value
    get retry_path

    expect(response).to have_http_status(:ok)
    expect(Follower.find(@follower.id)).to be_deleted
  ensure
    @release_provider << true
    sender&.join(10)
  end

  it "answers the seller's removal of a follower with a retryable 503 while the follow is held, and removes it on retry" do
    # `protect_from_forgery` null-sessions an unverified DELETE, which would sign the seller out first.
    ActionController::Base.allow_forgery_protection = false
    sign_in @seller
    sender = start_blast(hold_provider: true)
    Timeout.timeout(10) { @in_provider.pop }

    expect { delete follower_path(@follower.external_id) }.not_to raise_error
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Retry-After"]).to eq("60")
    expect(response.body).to be_empty
    expect(Follower.find(@follower.id)).to be_alive

    @release_provider << true
    sender.value
    delete follower_path(@follower.external_id)

    expect(response).to redirect_to(followers_path)
    expect(Follower.find(@follower.id)).to be_deleted
  ensure
    ActionController::Base.allow_forgery_protection = true
    @release_provider << true
    sender&.join(10)
  end

  it "answers a buyer's unsubscribe link with a retryable 503 while their follow is held, and unsubscribes on retry" do
    purchase = create(:purchase, :from_seller, seller: @seller, email: @follower.email)
    sender = start_blast(hold_provider: true)
    Timeout.timeout(10) { @in_provider.pop }
    path = unsubscribe_purchase_path(purchase.secure_external_id(scope: "unsubscribe"))

    expect { get path }.not_to raise_error
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Retry-After"]).to eq("60")
    expect(Follower.find(@follower.id)).to be_alive
    retry_path = expect_retry_page_for(path)

    @release_provider << true
    sender.value
    get retry_path

    expect(response).to have_http_status(:ok)
    expect(Follower.find(@follower.id)).to be_deleted
    expect(purchase.reload.can_contact).to be(false)
  ensure
    @release_provider << true
    sender&.join(10)
  end
end
