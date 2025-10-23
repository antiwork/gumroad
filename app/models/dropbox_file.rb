# frozen_string_literal: true

class DropboxFile < ApplicationRecord
  include ExternalId

  # A Dropbox file always belongs to a user. This is done because without it we could not fetch the dropbox files
  # for the user when they visit an upload page.
  belongs_to :user, optional: true
  # A Dropbox file can belong to a product file if it was successfully transferred to s3 and submitted by the user in a
  # product edit/product creation page. We need this to prevent rendering of dropbox files that have already been
  # turned into product files on upload pages.
  belongs_to :product_file, optional: true
  # A Dropbox file can belong to a link if it was added to a product in product edit or was associated on product
  # creation. We do this to prevent rendering of dropbox files on the product creation page that were added on the edit page.
  # Dropbox files added to the edit page of a product should only appear for that product.
  belongs_to :link, optional: true

  include JsonData

  after_commit :schedule_dropbox_file_analyze, on: :create

  validates_presence_of :dropbox_url

  scope :available, -> { where(deleted_at: nil, link_id: nil, product_file_id: nil) }
  scope :available_for_product, -> { where(deleted_at: nil, product_file_id: nil) }

  # Normal dropbox file transitions:
  #
  # in_progress  →  successfully_uploaded
  #
  #              →  cancelled (by user in ui)
  #
  #              →  failed (could never finish transfer)
  #
  #              →  deleted (by user in ui)
  #
  state_machine :state, initial: :in_progress do
    after_transition any => %i[cancelled failed deleted], do: :update_deleted_at!

    event :mark_successfully_uploaded do
      transition in_progress: :successfully_uploaded
    end

    event :mark_cancelled do
      transition in_progress: :cancelled
    end

    event :mark_failed do
      transition in_progress: :failed
    end

    event :mark_deleted do
      transition successfully_uploaded: :deleted
    end
  end

  def deleted?
    !in_progress? || deleted_at.present?
  end

  def update_deleted_at!
    update!(deleted_at: Time.current)
  end

  def self.create_with_file_info(raw_file_info)
    dropbox_file = DropboxFile.new
    dropbox_file.dropbox_url = raw_file_info[:link]
    # Dropbox direct file links expire after 4 hours. Dropbox does not provide a timestamp for the expiration so
    # we are creating one here.
    dropbox_file.expires_at = 4.hours.from_now
    file_info = clean_file_info(raw_file_info)
    dropbox_file.json_data = file_info
    dropbox_file.save!
    dropbox_file
  end

  def schedule_dropbox_file_analyze
    TransferDropboxFileToS3Worker.perform_in(5.seconds, id)
  end

  def transfer_to_s3
    return if cancelled? || deleted? || failed?

    mark_failed! if Time.current > expires_at
    extension = File.extname(dropbox_url).delete(".")
    set_json_data_for_attr("filetype", extension)
    FILE_REGEX.each do |file_type, regex|
      if extension.match(regex)
        set_json_data_for_attr("filegroup", file_type.split("_")[-1])
        break
      end
    end
    s3_guid = "db" + (SecureRandom.uuid.split("")[1..-1] - ["-"]).join
    filename = json_data_for_attr("file_name")
    multipart_transfer_to_s3(filename, s3_guid)
    self
  end

  def multipart_transfer_to_s3(filename, s3_guid)
    extname = File.extname(dropbox_url)
    tempfile = Tempfile.new([s3_guid, extname], binmode: true)
    HTTParty.get(dropbox_url, stream_body: true, follow_redirects: true) do |fragment|
      tempfile.write(fragment)
    end
    tempfile.close

    destination_key = "attachments/#{s3_guid}/original/#{filename}"
    Aws::S3::Resource.new.bucket(S3_BUCKET).object(destination_key).upload_file(tempfile.path,
                                                                                content_type: fetch_content_type)
    self.s3_url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{destination_key}"
    mark_successfully_uploaded!
  end

  def self.clean_file_info(raw_file_info)
    cleaned_file_info = {}
    cleaned_file_info[:file_name] = raw_file_info[:name]
    cleaned_file_info[:file_size] = raw_file_info[:bytes].to_i
    cleaned_file_info
  end

  def as_json(_options = {})
    {
      dropbox_url:,
      external_id:,
      s3_url:,
      user_id: user.try(:external_id),
      product_file_id: product_file.try(:external_id),
      link_id: link.try(:external_id),
      expires_at:,
      name: json_data_for_attr("file_name"),
      bytes: json_data_for_attr("file_size"),
      state:
    }
  end

  private
    def fetch_content_type
      MIME::Types.type_for(dropbox_url).first.to_s.presence
    end
end
