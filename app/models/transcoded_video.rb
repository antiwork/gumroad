# frozen_string_literal: true

class TranscodedVideo < ApplicationRecord
  include FlagShihTzu, Deletable, CdnDeletable

  self.ignored_columns += [:product_file_id]

  has_paper_trail

  belongs_to :link, optional: true

  delegated_type :streamable, types: %w[ProductFile], optional: true

  validates_presence_of :original_video_key, :transcoded_video_key

  before_save :assign_default_last_accessed_at

  has_flags 1 => :is_hls,
            2 => :via_grmc,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  state_machine(:state, initial: :processing) do
    event :mark_completed do
      transition processing: :completed
    end

    event :mark_error do
      transition processing: :error
    end
  end

  scope :completed,     -> { where(state: "completed") }
  scope :processing,    -> { where(state: "processing") }
  scope :s3, -> { } # assume they're all on S3 (needed for CdnDeletable)

  def mark(state)
    send("mark_#{state}")
  end

  def filename
    # filename is irrelevant for hls since we don't allow hls transcoded videos to be downloaded.
    is_hls? ? "" : transcoded_video_key.split("/").last
  end

  # note: when updating, last_accessed_at should be set to the same value for all the same transcoded_video_key
  def assign_default_last_accessed_at
    self.last_accessed_at ||= Time.current
  end

  def has_alive_duplicate_files?
    TranscodedVideo.alive.where(transcoded_video_key:).exists?
  end

  def mark_deleted!
    super

    if streamable&.is_transcoded_for_hls? && !has_alive_duplicate_files?
      streamable.update!(is_transcoded_for_hls: false)
    end
  end
end
