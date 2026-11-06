# frozen_string_literal: true

require "spec_helper"

describe RecordUtmLinkVisitJob do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:buyer) { create(:user) }
  let(:visited_at) { Time.utc(2026, 11, 6, 12, 0, 0, 123_456) }
  let(:visit) do
    {
      "seller_id" => seller.id,
      "target_resource_type" => "product_page",
      "target_resource_id" => product.id,
      "utm_params" => { "utm_source" => "x", "utm_medium" => "y", "utm_campaign" => "z", "utm_term" => nil, "utm_content" => nil },
      "user_id" => buyer.id,
      "referrer" => "https://example.com/r",
      "ip_address" => "54.234.242.13",
      "user_agent" => "UA",
      "browser_guid" => "guid-1",
      "visited_at_us" => (visited_at.to_r * 1_000_000).to_i,
      "paper_trail" => { "remote_ip" => "54.234.242.13", "request_path" => "/l/#{product.unique_permalink}", "request_uuid" => "uuid-1" },
    }
  end

  it "records the visit at its time, under the request's PaperTrail metadata", versioning: true do
    expect do
      expect { described_class.new.perform(visit) }.to change(UtmLink, :count).by(1)
    end.to change(UtmLinkVisit, :count).by(1)

    utm_link = UtmLink.last
    expect(utm_link).to have_attributes(seller:, target_resource_type: "product_page", target_resource_id: product.id, utm_source: "x",
                                        browser_guid: "guid-1", ip_address: "54.234.242.13", first_click_at: visited_at, last_click_at: visited_at)
    recorded = utm_link.utm_link_visits.last
    expect(recorded).to have_attributes(user: buyer, referrer: "https://example.com/r", user_agent: "UA", browser_guid: "guid-1", created_at: visited_at)
    expect(recorded.versions.last).to have_attributes(event: "create", whodunnit: buyer.id.to_s, remote_ip: "54.234.242.13",
                                                      request_path: "/l/#{product.unique_permalink}", request_uuid: "uuid-1")
    expect(UpdateUtmLinkStatsJob).to have_enqueued_sidekiq_job(utm_link.id)
  end

  it "keeps the link's click range in order for a visit recorded after a later one" do
    utm_link = create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product.id, utm_source: "x", utm_medium: "y",
                                 utm_campaign: "z", first_click_at: visited_at + 1.minute, last_click_at: visited_at + 2.minutes)

    described_class.new.perform(visit)

    expect(utm_link.reload).to have_attributes(first_click_at: visited_at, last_click_at: visited_at + 2.minutes)
  end

  it "records nothing for a seller that's gone" do
    expect { described_class.new.perform(visit.merge("seller_id" => 0)) }.not_to change(UtmLinkVisit, :count)
  end

  it "records nothing on a link the seller paused" do
    create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product.id, utm_source: "x", utm_medium: "y",
                      utm_campaign: "z", disabled_at: Time.current)

    expect { described_class.new.perform(visit) }.not_to change(UtmLinkVisit, :count)
  end
end
