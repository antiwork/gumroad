# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "a product with 'Download all' buttons on file embed groups" do
  before do
    file1 = create(:product_file, display_name: "File 1")
    file2 = create(:product_file, display_name: "File 2")
    @file3 = create(:product_file, display_name: "File 3")
    file4 = create(:product_file, display_name: "File 4")
    file5 = create(:product_file, display_name: "File 5")
    file6 = create(:product_file, filetype: "link", url: "https://www.google.com")
    file7 = create(:product_file, filetype: "link", url: "https://www.gumroad.com")
    file8 = create(:product_file, filetype: "link", url: "https://www.twitter.com")
    @file9 = create(:product_file, display_name: "File 9")
    file10 = create(:product_file, display_name: "File 10", size: 400000000)
    file11 = create(:product_file, display_name: "File 11", size: 300000000)
    product.product_files = [file1, file2, @file3, file4, file5, file6, file7, file8, @file9, file10, file11]
    folder1_id = SecureRandom.uuid
    folder2_id = SecureRandom.uuid
    page1_description = [
      { "type" => "fileEmbedGroup",
        "attrs" => { "name" => "folder 1", "uid" => folder1_id },
        "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
        ] },
      { "type" => "fileEmbedGroup",
        "attrs" => { "name" => "", "uid" => SecureRandom.uuid },
        "content" => [{ "type" => "fileEmbed", "attrs" => { "id" => @file3.external_id, "uid" => SecureRandom.uuid } }] },
      { "type" => "fileEmbedGroup",
        "attrs" => { "name" => "only 1 downloadable file", "uid" => SecureRandom.uuid },
        "content" => [{ "type" => "fileEmbed", "attrs" => { "id" => file8.external_id, "uid" => SecureRandom.uuid } },
                      { "type" => "fileEmbed", "attrs" => { "id" => @file9.external_id, "uid" => SecureRandom.uuid } }] }
    ]
    page2_description = [
      { "type" => "fileEmbedGroup",
        "attrs" => { "name" => "Page 2 folder", "uid" => folder2_id },
        "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
        ] },
      { "type" => "fileEmbedGroup",
        "attrs" => { "name" => "no downloadable files", "uid" => SecureRandom.uuid },
        "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file6.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file7.external_id, "uid" => SecureRandom.uuid } },
        ] },
      { "type" => "fileEmbedGroup",
        "attrs" => { "name" => "total file size exceeds limit", "uid" => SecureRandom.uuid },
        "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file10.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file11.external_id, "uid" => SecureRandom.uuid } },
        ] }
    ]
    create(:rich_content, entity: product, title: "Page 1", description: page1_description)
    create(:rich_content, entity: product, title: "Page 2", description: page2_description)

    @page1_folder_archive = product.product_files_archives.new(folder_id: folder1_id)
    @page1_folder_archive.set_url_if_not_present
    @page1_folder_archive.product_files = [file1, file2]
    @page1_folder_archive.save!
    @page1_folder_archive.mark_in_progress!
    @page1_folder_archive.mark_ready!

    @page2_folder_archive = product.product_files_archives.new(folder_id: folder2_id)
    @page2_folder_archive.set_url_if_not_present
    @page2_folder_archive.product_files = [file4, file5]
    @page2_folder_archive.save!
    @page2_folder_archive.mark_in_progress!
    @page2_folder_archive.mark_ready!
  end

  it "shows 'Download all' buttons on file embed groups" do
    visit(url)

    within_file_group("folder 1") do
      expect(page).to have_disclosure("Download all")
    end

    within_file_group("Untitled") do
      # for the single-file case, we use a link for the direct download URL
      # since no async zipping is required
      download_path = if url_redirect.present?
        url_redirect_download_product_files_path(url_redirect.token, { product_file_ids: [@file3.external_id] })
      else
        download_product_files_path({ product_file_ids: [@file3.external_id], product_id: product.external_id })
      end
      select_disclosure "Download all" do
        expect(page).to have_link("Download file", href: download_path)
      end
    end

    select_tab("Page 2")

    within_file_group("no downloadable files") do
      expect(page).to_not have_disclosure("Download all")
    end

    within_file_group("total file size exceeds limit") do
      expect(page).to_not have_disclosure("Download all")
    end

    expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).with(@page2_folder_archive.s3_key, @page2_folder_archive.s3_filename).and_return("https://example.com/zip-archive.zip")
    within_file_group("Page 2 folder") do
      select_disclosure "Download all" do
        click_on "Download as ZIP"
      end
    end
    expect(page).to have_current_path "https://example.com/zip-archive.zip"
  end

  it "downloads the individual file when pressing 'Download all' for a file embed group with only 1 downloadable file" do
    expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).with(@file9.s3_key, @file9.s3_filename, is_video: false).and_return("https://example.com/file.srt")

    visit(url)

    within_file_group("only 1 downloadable file") do
      select_disclosure "Download all" do
        click_on "Download file"
      end
      wait_for_ajax
    end
  end

  it "shows 'Zipping files...' when the folder archive is not ready when pressing 'Download all'" do
    @page1_folder_archive.mark_deleted!

    visit(url)

    within_file_group("folder 1") do
      select_disclosure "Download all" do
        click_on "Download as ZIP"
        expect(page).to have_button("Zipping files...", disabled: true)
      end
    end

    if url_redirect.present?
      # For the download page
      expect_any_instance_of(UrlRedirectsController).to receive(:url_redirect_download_archive_url).with(url_redirect.token, { folder_id:  @page1_folder_archive.folder_id }).and_return("https://example.com/zip-archive.zip")

      @page1_folder_archive.mark_undeleted!

      expect(page).to have_alert(text: "Your ZIP file is ready! Download")
      expect(page).to have_link("Download", href: "https://example.com/zip-archive.zip")
    else
      # For the product edit page
      expect_any_instance_of(SignedUrlHelper).to receive(:download_folder_archive_url).with(@page1_folder_archive.folder_id, { variant_id: nil, product_id: product.external_id }).and_return("https://example.com/zip-archive.zip")
      @page1_folder_archive.mark_undeleted!
      expect(page).to have_current_path "https://example.com/zip-archive.zip"
    end
  end

  it "saves the files to Dropbox when pressing 'Save to Dropbox'" do
    visit(url)
    expect_any_instance_of(url_redirect.present? ? UrlRedirectsController : ProductFilesUtilityController).to receive(:download_product_files).and_call_original
    product.product_files.delete_all # otherwise the dropbox call fails on the client

    within_file_group("folder 1") do
      select_disclosure "Download all" do
        click_on "Save to Dropbox"
        wait_for_ajax
      end
    end
  end
end
