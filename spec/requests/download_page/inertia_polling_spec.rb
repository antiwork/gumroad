# frozen_string_literal: true

require "spec_helper"

describe "Download page Inertia polling", type: :request do
  def partial_headers(partial_data)
    {
      "X-Inertia" => "true",
      "X-Inertia-Partial-Component" => "UrlRedirects/DownloadPage",
      "X-Inertia-Partial-Data" => partial_data,
    }
  end

  it "returns audio durations via partial reload without side effects" do
    product = create(:product)
    audio = create(:listenable_audio, duration: 120)
    product.product_files = [audio]
    product.save!
    purchase = create(:purchase, link: product)
    url_redirect = create(:url_redirect, link: product, purchase:)

    initial_uses = url_redirect.reload.uses
    expect do
      get url_redirect_download_page_path(url_redirect.token),
          params: { file_ids: [audio.external_id] },
          headers: partial_headers("audio_durations")
    end.not_to change(ConsumptionEvent, :count)

    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Inertia"]).to eq("true")
    expect(response.parsed_body.fetch("component")).to eq("UrlRedirects/DownloadPage")
    expect(response.parsed_body.dig("props", "audio_durations")).to eq(audio.external_id => 120)
    expect(response.parsed_body.dig("props", "dropbox_api_key")).to be_nil
    expect(url_redirect.reload.uses).to eq(initial_uses)
  end

  it "returns latest media locations via partial reload without side effects" do
    product = create(:product)
    readable_document = create(:readable_document)
    product.product_files = [readable_document]
    product.save!
    purchase = create(:purchase, link: product)
    url_redirect = create(:url_redirect, link: product, purchase:)
    media_timestamp = Time.current.change(usec: 0)
    create(
      :media_location,
      url_redirect_id: url_redirect.id,
      purchase_id: purchase.id,
      product_file_id: readable_document.id,
      product_id: product.id,
      location: 5,
      consumed_at: media_timestamp
    )

    initial_uses = url_redirect.reload.uses
    expect do
      get url_redirect_download_page_path(url_redirect.token), headers: partial_headers("latest_media_locations")
    end.not_to change(ConsumptionEvent, :count)

    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Inertia"]).to eq("true")
    expect(response.parsed_body.fetch("component")).to eq("UrlRedirects/DownloadPage")
    expect(response.parsed_body.dig("props", "latest_media_locations")).to eq(
      readable_document.external_id => {
        "location" => 5,
        "timestamp" => media_timestamp.as_json,
        "unit" => "page_number",
      }
    )
    expect(response.parsed_body.dig("props", "dropbox_api_key")).to be_nil
    expect(url_redirect.reload.uses).to eq(initial_uses)
  end

  it "falls back to a full page response for non-whitelisted partial props" do
    url_redirect = create(:url_redirect)
    initial_uses = url_redirect.reload.uses

    expect do
      get url_redirect_download_page_path(url_redirect.token), headers: partial_headers("audio_durations,content")
    end.to change(ConsumptionEvent, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Inertia"]).to eq("true")
    expect(response.parsed_body.fetch("component")).to eq("UrlRedirects/DownloadPage")
    expect(response.parsed_body.dig("props", "content")).to be_present
    expect(response.parsed_body.dig("props", "dropbox_api_key")).to eq(DROPBOX_PICKER_API_KEY)
    expect(url_redirect.reload.uses).to eq(initial_uses + 1)
  end
end
