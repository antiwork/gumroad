# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::UrlRedirectsController, type: :controller do
  it "does not redirect to the original upload while a stampable PDF is unstamped" do
    product = create(:product, price_cents: 0)
    purchase = create(:purchase, link: product, price_cents: 0)
    url_redirect = create(:url_redirect, link: product, purchase:)
    pdf = create(:readable_document, link: product, pdf_stamp_enabled: true)
    allow_any_instance_of(UrlRedirect).to receive(:signed_location_for_file).and_return("https://example.com/unstamped.pdf")

    expect do
      get :download, params: { token: url_redirect.token,
                               product_file_id: pdf.external_id,
                               mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }
    end.to_not change(ConsumptionEvent, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["message"]).to eq("We are preparing the file for download. You will receive an email when it is ready.")
    expect(response.body).not_to include("unstamped.pdf")
    expect(PdfStampingService.buyer_notification_requested?(purchase.id)).to be(true)
    expect(StampPdfForPurchaseJob).to have_enqueued_sidekiq_job(purchase.id, true).on("critical")
    expect(url_redirect.reload.uses).to eq(0)
  end
end
