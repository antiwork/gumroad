# frozen_string_literal: true

class SavePublicFilesService
  attr_reader :resource, :files_params, :content, :contract

  def initialize(resource:, files_params:, content:, contract: nil)
    @resource = resource
    @files_params = files_params.presence || []
    @content = content.to_s
    @contract = contract
  end

  def process
    # Product::SaveContract, Rule 1: a request that did not submit
    # `public_files` and did not explicitly ask for a deletion must leave this
    # collection completely alone. That means not just skipping the
    # schedule-for-deletion pass — it means not touching the description at
    # all, because clean_invalid_file_embeds runs against valid_file_ids and
    # any pass through it can strip <public-file-embed> nodes. The 10-day
    # deletion delay protects the file rows, but the description damage was
    # always immediate; returning the content byte-identical is the only safe
    # answer here.
    return content if contract_enforced? && no_public_files_intent?

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
        .reject(&:scheduled_for_deletion?)
        .select { deletable?(_1, file_ids_in_content) }
        .each(&:schedule_for_deletion!)
    end

    # With the contract enforced, "not mentioned in the payload" is no longer
    # a deletion signal (Rule 1) — only an explicit deleted_ids entry or an
    # explicit clear-all may schedule a file (Rule 2). Without the contract
    # (or with the kill switch off) this is the historical diff-based rule,
    # byte-identical to the previous behaviour.
    def deletable?(file, file_ids_in_content)
      if contract_enforced?
        return true if contract.cleared?(:public_files)

        file.public_id.in?(contract.deleted_ids(:public_files))
      elsif contract&.degraded?
        # Flag lookup failed, so we cannot tell whether the contract governs
        # this save. The legacy rule below infers deletion from the description
        # markup — and scheduling a public file for deletion also strips its
        # <public-file-embed> node — so a Redis blip would silently rewrite the
        # description. Suppress the inference; explicit intent is absent here by
        # definition. See Product::SaveContract#degraded?.
        false
      else
        !file.public_id.in?(file_ids_in_content)
      end
    end

    def contract_enforced?
      contract.present? && contract.enforced?
    end

    # True when this request expressed no intent about public_files at all:
    # the collection wasn't submitted (absent and [] read the same, Rule 1)
    # and no explicit deletion targets it. In that case #process must be a
    # no-op for both the rows and the description.
    def no_public_files_intent?
      !contract.submitted?(:public_files) &&
        contract.deleted_ids(:public_files).empty? &&
        !contract.cleared?(:public_files)
    end

    def clean_invalid_file_embeds(doc, persisted_files)
      valid_file_ids = persisted_files.reject(&:scheduled_for_deletion?).map(&:public_id)
      doc.css("public-file-embed").each do |node|
        id = node.attr("id")
        node.remove if id.blank? || !id.in?(valid_file_ids)
      end
    end
end
