# frozen_string_literal: true

class SavePublicFilesService
  attr_reader :resource, :files_params, :content

  def initialize(resource:, files_params:, content:)
    @resource = resource
    @files_params = files_params.presence || []
    @content = content.to_s
  end

  def process
    ActiveRecord::Base.transaction do
      persisted_files = resource.alive_public_files
      doc = Nokogiri::HTML.fragment(content)
      file_ids_in_content = extract_file_ids_from_content(doc)

      update_existing_files(persisted_files, file_ids_in_content)
      schedule_unused_files_for_deletion(persisted_files, file_ids_in_content)
      clean_invalid_file_embeds(doc, persisted_files)

      doc.to_html
    end
  end

  private
    def extract_file_ids_from_content(doc)
      saved_file_ids_from_files_params = files_params.filter { _1.dig("status", "type") == "saved" }.map { _1["id"] }
      doc.css("public-file-embed").map { _1.attr("id") }.compact.select { _1.in?(saved_file_ids_from_files_params) }
    end

    def update_existing_files(persisted_files, file_ids_in_content)
      files_params
        .select { _1["id"].in?(file_ids_in_content) }
        .each do |file_params|
          persisted_file = persisted_files.find { _1.public_id == file_params["id"] }
          next if persisted_file.nil?

          persisted_file.display_name = file_params["name"].presence || "Untitled"
          persisted_file.scheduled_for_deletion_at = nil
          persisted_file.save!
        end
    end

    def schedule_unused_files_for_deletion(persisted_files, file_ids_in_content)
      persisted_files
        .reject { _1.scheduled_for_deletion? || _1.public_id.in?(file_ids_in_content) }
        .each(&:schedule_for_deletion!)
    end

    def clean_invalid_file_embeds(doc, persisted_files)
      valid_file_ids = persisted_files.reject(&:scheduled_for_deletion?).map(&:public_id)
      doc.css("public-file-embed").each do |node|
        id = node.attr("id")
        node.remove if id.blank? || !id.in?(valid_file_ids)
      end
    end
end
