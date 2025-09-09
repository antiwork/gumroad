# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Dropbox uploads", type: :system, js: true do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }

  include_context "with switching account to user as admin for seller"

  before do
    visit edit_link_path(product.unique_permalink) + "/content"
  end

  it "embeds dropbox files successfully" do
    select_disclosure "Upload files" do
      pick_dropbox_file("/db_upload_testing/Download-Card.pdf")
    end
    select_disclosure "Upload files" do
      pick_dropbox_file("/db_upload_testing/SmallTestFile")
    end
    %w(Download-Card SmallTestFile).each do |file_name|
      expect(page).to have_embed(name: file_name)
      wait_for_file_embed_to_finish_uploading(name: file_name)
    end
    sleep 0.5 # wait for the editor to update the content
    save_change
    expect(product.reload.alive_product_files.count).to eq 2
    expect(product.alive_product_files.first.display_name).to eq("Download-Card")
    expect(product.alive_product_files.last.display_name).to eq("SmallTestFile")
    expect(product.alive_rich_contents.sole.description).to match_array([
                                                                          { "type" => "fileEmbed", "attrs" => { "id" => product.alive_product_files.first.external_id, "uid" => anything, "collapsed" => false } },
                                                                          { "type" => "fileEmbed", "attrs" => { "id" => product.alive_product_files.last.external_id, "uid" => anything, "collapsed" => false } },
                                                                          { "type" => "paragraph" }
                                                                        ])
  end

  it "allows to change dropbox file's name and description while the file is uploading" do
    select_disclosure "Upload files" do
      pick_dropbox_file("/db_upload_testing/Download-Card.pdf")
    end

    # Make sure the file row remains in "uploading" state while we edit the name and description
    allow_any_instance_of(DropboxFilesController).to receive(:index)

    toggle_disclosure "Upload files"
    within find_embed(name: "Download-Card") do
      click_on "Edit"
      fill_in "Name", with: "Greeting-Card"
      fill_in "Description", with: "This is a fancy greeting card!"
    end

    allow_any_instance_of(DropboxFilesController).to receive(:index).and_call_original
    wait_for_file_embed_to_finish_uploading(name: "Greeting-Card")
    sleep 0.5 # wait for the editor to update the content
    save_change
    product.reload
    uploaded_file = product.alive_product_files.sole
    expect(uploaded_file.display_name).to eq "Greeting-Card"
    expect(uploaded_file.description).to eq "This is a fancy greeting card!"
    expect(product.alive_rich_contents.sole.description).to match_array([
                                                                          { "type" => "fileEmbed", "attrs" => { "id" => uploaded_file.external_id, "uid" => anything, "collapsed" => false } },
                                                                          { "type" => "paragraph" }
                                                                        ])
  end

  it "allows users to cancel dropbox uploads" do
    select_disclosure "Upload files" do
      pick_dropbox_file("/db_upload_testing/Download-Card.pdf", true)
    end
    select_disclosure "Upload files" do
      pick_dropbox_file("/db_upload_testing/GumroadCreatorFAQ.pdf")
    end
    expect(page).to have_embed(name: "Download-Card")
    expect(page).to have_embed(name: "GumroadCreatorFAQ")
    wait_for_file_embed_to_finish_uploading(name: "GumroadCreatorFAQ")
    toggle_disclosure "Upload files"
    within find_embed(name: "Download-Card") do
      click_on "Cancel"
    end
    sleep 0.5 # wait for the editor to update the content
    save_change
    expect(page).to have_embed(name: "GumroadCreatorFAQ")
    expect(page).not_to have_embed(name: "Download-Card")
    expect(product.user.dropbox_files.count).to eq 2
    successful_dropbox_file = product.user.dropbox_files.reload.where(state: "successfully_uploaded").first
    expect(successful_dropbox_file.product_file).to eq product.alive_product_files.last
    expect(successful_dropbox_file.link).to eq product
    expect(successful_dropbox_file.json_data["file_name"]).to eq "GumroadCreatorFAQ.pdf"
    expect(successful_dropbox_file.s3_url).not_to be_nil
    cancelled_db_file = product.user.dropbox_files.reload.where.not(state: "successfully_uploaded").first
    expect(cancelled_db_file.product_file).to be_nil
    expect(cancelled_db_file.json_data["file_name"]).to eq "Download-Card.pdf"
    expect(product.alive_product_files.count).to eq 1
    expect(product.alive_rich_contents.sole.description).to match_array([
                                                                          { "type" => "fileEmbed", "attrs" => { "id" => successful_dropbox_file.product_file.external_id, "uid" => anything, "collapsed" => false } },
                                                                          { "type" => "paragraph" }
                                                                        ])
  end

  it "allows users to remove dropbox uploads" do
    select_disclosure "Upload files" do
      pick_dropbox_file("/db_upload_testing/Download-Card.pdf")
    end
    select_disclosure "Upload files" do
      pick_dropbox_file("/db_upload_testing/GumroadCreatorFAQ.pdf")
    end
    expect(page).to have_embed(name: "Download-Card")
    wait_for_file_embed_to_finish_uploading(name: "Download-Card")
    expect(page).to have_embed(name: "GumroadCreatorFAQ")
    wait_for_file_embed_to_finish_uploading(name: "GumroadCreatorFAQ")
    toggle_disclosure "Upload files"
    within find_embed(name: "Download-Card") do
      page.click
      select_disclosure "Actions" do
        click_on "Delete"
      end
    end
    sleep 0.5 # wait for the editor to update the content
    save_change
    expect(page).to have_embed(name: "GumroadCreatorFAQ")
    expect(page).not_to have_embed(name: "Download-Card")
    expect(product.user.dropbox_files.count).to eq 2
    successful_dropbox_file = product.user.dropbox_files.last
    expect(successful_dropbox_file.product_file).to eq product.alive_product_files.last
    expect(successful_dropbox_file.link).to eq product
    expect(successful_dropbox_file.json_data["file_name"]).to eq "GumroadCreatorFAQ.pdf"
    removed_db_file = product.user.dropbox_files.first
    expect(removed_db_file.product_file).to be_nil
    expect(removed_db_file.json_data["file_name"]).to eq "Download-Card.pdf"
    expect(product.alive_product_files.count).to eq 1
    expect(product.alive_rich_contents.sole.description).to match_array([
                                                                          { "type" => "fileEmbed", "attrs" => { "id" => successful_dropbox_file.product_file.external_id, "uid" => anything, "collapsed" => false } },
                                                                          { "type" => "paragraph" }
                                                                        ])
  end
end
