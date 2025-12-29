# frozen_string_literal: true

class AudienceExport < ApplicationRecord
  belongs_to :seller, class_name: "User"
  belongs_to :recipient, class_name: "User"
  has_many :chunks, class_name: "AudienceExportChunk", foreign_key: :export_id, dependent: :delete_all

  serialize :audience_options, type: Hash, coder: YAML

  validates :external_id, presence: true, uniqueness: true
  validates :audience_options, presence: true

  before_validation :set_external_id, on: :create

  private
    def set_external_id
      self.external_id ||= self.class.generate_external_id
    end

    def self.generate_external_id(max_retries: 10)
      retries = 0
      candidate = SecureRandom.alphanumeric(12).downcase

      while exists?(external_id: candidate)
        retries += 1
        raise "Failed to generate unique external_id after #{max_retries} attempts" if retries >= max_retries
        candidate = SecureRandom.alphanumeric(12).downcase
      end

      candidate
    end
end
