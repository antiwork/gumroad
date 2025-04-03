# frozen_string_literal: true

# Requires has_paper_trail on the model
#
module Versionable
  extend ActiveSupport::Concern

  # Reasonable limit of version records to query
  LIMIT = 100

  VersionInfoStruct = Struct.new(:created_at, :changes)

  # It returns a collection of VersionInfoStruct objects that contain changes from
  # at least one of the fields provided
  #
  def versions_for(*fields)
    attributes = fields.map(&:to_s)
    versions
      .reorder("id DESC")
      .limit(LIMIT)
      .map { |v| build_version_info(v, attributes) }
      .compact
      .select { |info| (info.changes.keys & attributes.map(&:to_s)).any? }
  end

  private
    def build_version_info(version, attributes)
      return if version.object_changes.blank?

      VersionInfoStruct.new(
        version.created_at,
        PaperTrail.serializer.load(version.object_changes).slice(*attributes)
      )
    end
end
