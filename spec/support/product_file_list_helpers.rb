# frozen_string_literal: true

# Helper methods for the new file list on the product edit page
# (do not use when on the product creation step)
module ProductFileListHelpers
  def have_file_row(name:, count: nil)
    options = { text: name, exact_text: true, count: }.compact
    have_selector("[aria-label=Files] [role=treeitem] h4", **options)
  end

  def find_file_row!(name:)
    fname = content_section.first("[role=treeitem] h4", text: name, exact_text: true, wait: 5)
    fname.ancestor("[role=treeitem]", order: :reverse, match: :first)
  end

  def have_embed(name:, count: nil)
    options = { text: name, exact_text: true, count: }.compact
    have_selector(".embed h4", **options)
  end

  def find_embed(name:)
    fname = page.first(".embed h4", text: name, exact_text: true, wait: 5)
    fname.ancestor(".embed")
  end

  def wait_for_file_embed_to_finish_uploading(name:)
    row = find_embed(name:)
    page.scroll_to row, align: :center
    row.find("h4").hover
    expect(row).not_to have_selector("[role='progressbar']")
  end

  def rename_file_embed(from:, to:)
    within find_embed(name: from) do
      click_on "Edit"
      fill_in "Name", with: to
      click_on "Close drawer"
    end
  end

  def have_input_labelled(label, with:)
    label_element = page.first("label", text: label, exact_text: true, wait: 5)
    input_id = label_element[:for]
    have_field(input_id, with:)
  end

  def have_subtitle_row(name:)
    have_selector("[role=\"listitem\"] h4", text: name, exact_text: true)
  end

  def attach_product_file(file)
    page.attach_file(file) do
      click_on "Computer files"
    end
  end

  def expect_focused(active_el)
    expect(page.driver.browser.switch_to.active_element).to eql(active_el.native)
  end

  def pick_dropbox_file(url, skip_transfer = false)
    dropbox_info = generate_dropbox_file_info_with_path(url)
    files = [{ bytes: dropbox_info[:bytes], icon: dropbox_info[:icon], link: dropbox_info[:link], name: dropbox_info[:name], id: dropbox_info[:id] }]
    page.execute_script("window.___dropbox_files_picked = #{files.to_json};")

    click_on "Dropbox files"

    sleep 1

    unless skip_transfer
      transfer_dropbox_upload(dropbox_url: dropbox_info[:link])
    end
  end

  def transfer_dropbox_upload(dropbox_url: nil)
    if dropbox_url
      dropbox_file = DropboxFile.where(dropbox_url:).last
    else
      dropbox_file = DropboxFile.last
    end
    stub_dropbox_file_transfer(dropbox_file)
    dropbox_file.transfer_to_s3
  end

  private
    def content_section
      page.first "[role=tree][aria-label=Files]"
    end

    def generate_dropbox_file_info_with_path(path)
      filename = File.basename(path)
      {
        bytes: 1024,
        icon: "",
        link: "https://dl.dropboxusercontent.com/test/#{SecureRandom.hex(8)}/#{filename}",
        name: filename,
        id: "id:#{SecureRandom.hex(16)}"
      }
    end

    def stub_dropbox_file_transfer(dropbox_file)
      allow(HTTParty).to receive(:get)
        .with(dropbox_file.dropbox_url, hash_including(:stream_body))
        .and_yield("fake file content")

      s3_resource = double("s3_resource")
      s3_bucket = double("s3_bucket")
      s3_object = double("s3_object")
      allow(Aws::S3::Resource).to receive(:new).and_return(s3_resource)
      allow(s3_resource).to receive(:bucket).and_return(s3_bucket)
      allow(s3_bucket).to receive(:object).and_return(s3_object)
      allow(s3_object).to receive(:upload_file).and_return(true)
    end
end
