# frozen_string_literal: true

class ProductFilesArchive < ApplicationRecord
  include ExternalId, S3Retrievable, SignedUrlHelper, Deletable, CdnDeletable

  has_paper_trail

  belongs_to :link, optional: true
  belongs_to :installment, optional: true
  belongs_to :variant, optional: true
  has_and_belongs_to_many :product_files

  after_create_commit :generate_zip_archive!

  state_machine :product_files_archive_state, initial: :queueing do
    before_transition any => :in_progress, do: :set_digest

    event :mark_failed do
      transition all => :failed
    end

    event :mark_in_progress do
      transition all => :in_progress
    end

    event :mark_ready do
      transition [:in_progress] => :ready
    end
  end

  validate :belongs_to_product_or_installment_or_variant

  has_s3_fields :url

  scope :ready, -> { where(product_files_archive_state: "ready") }
  scope :folder_archives, -> { where.not(folder_id: nil) }
  scope :entity_archives, -> { where(folder_id: nil) }

  delegate :user, to: :with_product_files_owner

  def has_alive_duplicate_files?
    false
  end

  def self.latest_ready_entity_archive
    entity_archives.alive.ready.last
  end

  def self.latest_ready_folder_archive(folder_id)
    folder_archives.alive.ready.where(folder_id:).last
  end

  def has_cdn_url?
    url&.starts_with?(S3_BASE_URL)
  end

  def folder_archive?
    folder_id.present?
  end

  def with_product_files_owner
    link || installment || variant
  end

  def generate_zip_archive!
    UpdateProductFilesArchiveWorker.perform_in(5.seconds, id)
  end

  # Overrides S3Retrievable s3_directory_uri
  def s3_directory_uri
    return unless s3?
    s3_url.split("/")[4, 4].join("/")
  end

  def set_url_if_not_present
    self.url ||= construct_url
  end

  def needs_updating?(new_product_files)
    new_files = new_product_files.archivable
    existing_files = product_files.archivable

    return true if rich_content_provider.nil? && (new_files.size != existing_files.size || new_files.in_order != existing_files.in_order)

    # Update if folder / file renamed or files re-arranged into different folders
    digest != files_digest(new_files)
  end

  def rich_content_provider
    link || variant
  end

  private
    def set_digest
      self.digest = files_digest(product_files.archivable)
    end

    def files_digest(files)
      rich_content_files = rich_content_provider&.map_rich_content_files_and_folders
      file_list = if rich_content_files.blank?
        files.map { |file| [file.folder&.external_id, file.folder&.name, file.external_id, file.name_displayable].compact.join("/") }.sort
      else
        rich_content_files = rich_content_files.select { |key, value| value[:folder_id] == folder_id } if folder_archive?
        rich_content_files.values.map do |info|
          page_info = folder_archive? ? [] : [info[:page_id], info[:page_title]]
          page_info.concat([info[:folder_id], info[:folder_name], info[:file_id], info[:file_name]]).flatten.compact.join("/")
        end.sort
      end

      Digest::SHA1.hexdigest(file_list.join("\n"))
    end

    def belongs_to_product_or_installment_or_variant
      return if [link, installment, variant].compact.length == 1

      errors.add(:base, "A product files archive needs to belong to an installment, a product or a variant")
    end

    def construct_url
      archive_filename = (folder_archive? ? (rich_content_provider.rich_content_folder_name(folder_id).presence || "Untitled") : with_product_files_owner.name).gsub(/\s+/, "_").tr("/", "-")
      s3_key = ["attachments_zipped", with_product_files_owner.user.external_id,
                with_product_files_owner.external_id, external_id, archive_filename].join("/")
      url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{s3_key}"
      # NOTE: Total url length must be 255 characters or less to fit MySQL column
      url.first(251) + ".zip"
    end
end
