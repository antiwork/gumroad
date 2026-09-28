# frozen_string_literal: true

require "spec_helper"

describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  # Eligible: the video has a player, the PDF has the in-browser reader.
  let!(:video) { create(:streamable_video, link: product) }
  let!(:pdf) { create(:readable_document, link: product) }
  # Not eligible: nothing in the browser can open a plain text file, so turning its download off
  # would leave the buyer with no way to open what they paid for.
  let!(:text) { create(:non_readable_document, link: product) }
  let!(:already_disabled) { create(:streamable_video, link: product, stream_only: true) }

  before { sign_in seller }

  def disable_downloads(permalink = product.unique_permalink)
    post :disable_downloads_for_all_files, params: { id: permalink }, as: :json
  end

  it "turns downloads off for every eligible file and reports what changed" do
    disable_downloads

    expect(response).to be_successful
    expect(response.parsed_body).to include(
      "success" => true,
      "disabled_count" => 2,
      "already_disabled_count" => 1,
      "ineligible_count" => 1,
    )
    expect(response.parsed_body["disabled_file_ids"]).to contain_exactly(video.external_id, pdf.external_id)

    expect(video.reload.stream_only?).to eq(true)
    expect(pdf.reload.stream_only?).to eq(true)
    # A file that cannot be opened in the browser, and one already switched off, are left alone.
    expect(text.reload.stream_only?).to eq(false)
    expect(already_disabled.reload.stream_only?).to eq(true)
  end

  # gp#2916 picked option 3: the change keeps applying to buyers who already paid, and this action
  # must not quietly grandfather them.
  it "removes the download for a buyer who purchased before the flip" do
    # The purchase factory charges through Gumroad's own merchant account.
    create(:merchant_account, user: nil)
    purchase = create(:purchase, link: product)
    url_redirect = create(:url_redirect, purchase:, link: product)
    expect(url_redirect.is_file_downloadable?(video)).to eq(true)

    disable_downloads

    expect(url_redirect.is_file_downloadable?(video.reload)).to eq(false)
  end

  it "leaves another product's files alone" do
    other_product = create(:product, user: seller)
    other_video = create(:streamable_video, link: other_product)

    disable_downloads

    expect(other_video.reload.stream_only?).to eq(false)
  end

  # The archive pass: the same in-transaction invalidation and post-commit rebuild the editor
  # save runs after a content change, so a zip built before the flip does not outlive it.
  it "enqueues the archive rebuild" do
    disable_downloads

    expect(GenerateProductFilesArchivesJob).to have_enqueued_sidekiq_job(product.id)
  end

  it "deletes a ready folder archive that holds a flipped file" do
    folder_id = SecureRandom.uuid
    create(:rich_content, entity: product, description: [
             { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder", "uid" => folder_id }, "content" => [
               { "type" => "fileEmbed", "attrs" => { "id" => video.external_id, "uid" => SecureRandom.uuid } },
               { "type" => "fileEmbed", "attrs" => { "id" => text.external_id, "uid" => SecureRandom.uuid } },
             ] }
           ])
    archive = product.product_files_archives.create!(folder_id:, product_files: [video, text])
    archive.mark_in_progress!
    archive.mark_ready!

    disable_downloads

    expect(archive.reload.deleted?).to eq(true)
  end

  it "does nothing when no file can change" do
    product.product_files.each { |file| file.update!(stream_only: true) }

    disable_downloads

    expect(response.parsed_body["disabled_count"]).to eq(0)
    expect(GenerateProductFilesArchivesJob).not_to have_enqueued_sidekiq_job(product.id)
  end

  it "refuses a product the current user cannot access" do
    other_product = create(:product)
    other_video = create(:streamable_video, link: other_product)

    expect { disable_downloads(other_product.unique_permalink) }.to raise_error(ActionController::RoutingError)

    expect(other_video.reload.stream_only?).to eq(false)
  end
end
