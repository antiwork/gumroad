# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Marketing recommendations" do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, name: "Gumstein Letters") }
  let!(:earlier_product) { create(:product, user: seller, name: "Earlier Letters") }
  let(:can_send_emails) { true }
  let(:holdout) { false }

  before do
    create(:payment_completed, user: seller) if can_send_emails
    allow_any_instance_of(User).to receive(:sales_cents_total)
      .and_return(can_send_emails ? Installment::MINIMUM_SALES_CENTS_VALUE : 0)
    # Assigned up front like the controller spec does: the lazy assignment reads the
    # seller's lifetime sales off the purchase search index, which a fresh local test DB
    # does not have.
    create(:marketing_holdout_assignment, user: seller, marketing_holdout: holdout)
    Feature.activate_user(:auto_marketing, seller)
    host! DOMAIN
    sign_in(seller)
  end

  def email_channel
    get product_marketing_actions_path(product.unique_permalink, "json")
    expect(response).to be_successful, "GET returned #{response.status}: #{response.body.to_s[0, 300]}"
    response.parsed_body["channels"].find { _1["channel"] == "email" }
  end

  # Counts are served from Elasticsearch and the indexing jobs stay enqueued in the fake
  # Sidekiq queue, so index the members synchronously first. Same recipe as the recipient
  # count controller's spec.
  def index_audience
    recreate_model_index(AudienceMember)
    AudienceMember.find_each do |member|
      ElasticsearchIndexerWorker.new.perform("index", { "record_id" => member.id, "class_name" => "AudienceMember" })
    end
    AudienceMember.__elasticsearch__.refresh_index!
  end

  it "shows the launch email draft with per-segment counts that exclude the new product's buyers" do
    create(:purchase, seller:, link: earlier_product, email: "earlier-customer@example.com")
    # Bought the launch product, so this address is left out of every segment.
    create(:purchase, seller:, link: product, email: "new-buyer@example.com")
    create(:active_follower, user: seller, email: "follower@example.com")
    # A follower who also bought the launch product: still excluded.
    create(:active_follower, user: seller, email: "new-buyer@example.com")
    index_audience

    email = email_channel

    expect(email).to include("eligible" => true, "live" => true, "blocked_reason" => nil)
    expect(email["counts"]).to eq("customers" => 1, "followers" => 1, "affiliates" => 0, "total" => 2)
    expect(email["draft"]).to include("subject" => "Gumstein Letters", "state" => "draft")

    draft = Installment.find_by_external_id(email["draft"]["id"])
    expect(draft.not_bought_products).to eq([product.unique_permalink])
    expect(draft.installment_type).to eq(Installment::AUDIENCE_TYPE)
    expect(draft.published_at).to be_nil
    expect(draft.ready_to_publish?).to eq(false)
  end

  it "drafts one email per product and never sends it" do
    expect { email_channel }.to change { seller.installments.alive.count }.by(1)
    expect { email_channel }.not_to change { seller.installments.alive.count }

    expect(SendPostBlastEmailsJob.jobs).to be_empty
    expect(PostEmailBlast.count).to eq(0)
    expect(seller.installments.alive.last.blasts).to be_empty
  end

  it "leaves the draft the seller owns alone" do
    email = email_channel
    draft = Installment.find_by_external_id(email["draft"]["id"])
    draft.update!(message: "<p>My own words.</p>")
    product.update!(description: "<p>A new first sentence.</p>")

    expect(email_channel).to include("eligible" => true)
    expect(draft.reload.message).to eq("<p>My own words.</p>")
    expect(seller.installments.alive.count).to eq(1)
  end

  context "when the seller is held out" do
    let(:holdout) { true }

    it "gets nothing at all" do
      expect do
        get product_marketing_actions_path(product.unique_permalink, "json")
      end.not_to change { [Marketing::Action.count, Installment.count] }

      expect(response).to have_http_status(:not_found)
    end
  end

  context "when the seller cannot send emails yet" do
    let(:can_send_emails) { false }

    it "reports the gate reason and drafts nothing" do
      expect { email_channel }.not_to change { Installment.count }

      email = response.parsed_body["channels"].find { _1["channel"] == "email" }
      expect(email).to include("eligible" => false, "draft" => nil)
      expect(email["blocked_reason"]).to eq("You can email your customers once you've made at least $100 in sales and received a payout.")
      expect(email["requirements"]).to eq("sales_cents_total" => 0,
                                          "min_sales_cents_required" => Installment::MINIMUM_SALES_CENTS_VALUE)
      expect(email["action"]).to include("status" => "blocked", "error_code" => "email_eligibility_not_met")
    end
  end
end
