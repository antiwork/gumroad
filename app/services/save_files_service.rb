# frozen_string_literal: true

class SaveFilesService
  # ProductFile.as_json (editor/internal serialization — not the smaller v2
  # GET shape) includes these derived keys, but ProductFile cannot write them
  # back. Keep writable flag-backed as_json attributes out of this list.
  UNWRITABLE_SERIALIZED_FILE_KEYS = %i[
    file_size extension is_pdf is_streamable is_transcoding_in_progress attached_product_name status
  ].freeze

  delegate :product_files, to: :owner
  attr_reader :owner, :params, :rich_content_params, :contract

  def self.perform(*args, **kwargs)
    new(*args, **kwargs).perform
  end

  # Params:
  # +owner+ - an object of a model having the WithProductFiles mixin
  # +params+ - a nested hash of product files' attributes:
  #                     {
  #                       files: {
  #                          "0" => {
  #                                   unique_url_identifier: "c7675710fc594849b5d37715c5be5383",
  #                                   display_name: "Ruby video tutorial",
  #                                   description: "100 detailed recipes",
  #                                   subtitles: {
  #                                               "aghsha2828ah": {
  #                                                                 url: "#{AWS_S3_ENDPOINT}/gumroad_dev/attachments/5427372145012/5db55fc31ed743818107b00ce6ad100b/original/sample.srt",
  #                                                                 language: "English"
  #                                                               },
  #                                               ...
  #                                              }
  #                                 },
  #                          "1" => {
  #                                 ...
  #                                 }
  #                       },
  #                       folders: {
  #                         "0" => {
  #                           id: "absh2226677aaa",
  #                           name: "Ruby Recipes",
  #                         },
  #                         "1" => {
  #                           ...
  #                         }
  #                       }
  #                     }
  # +contract+ - optional Product::SaveContract (gumroad-private#1379). Only
  # the product editor's save path passes one; every other caller (API v2,
  # installments, workflows, customer emails) constructs the service without
  # it and is therefore untouched by construction. When present AND enforced,
  # the editor contract applies to the :files collection:
  #   * absent == [] == "no changes" — never deletes (Rule 1)
  #   * deletion happens only via explicit deleted_ids / clear-all (Rule 2)
  # With the flag off (contract.enforced? == false) behaviour is byte-identical
  # to the legacy path below.
  def initialize(owner, params, rich_content_params = [], contract: nil)
    @owner = owner
    @params = params
    @rich_content_params = rich_content_params
    @contract = contract
  end

  def perform
    return perform_under_contract if contract&.enforced?

    params[:files] = [] unless params.key?(:files)

    save_files_params = updated_file_params(params[:files])
    # A flag-store outage leaves us unable to tell whether the contract applies.
    # The legacy call below deletes every file missing from the payload, so on
    # that path we keep the writes and drop the implicit deletion: the request
    # never asked for one, and not deleting is recoverable while deleting is
    # not. See Product::SaveContract#degraded?.
    return owner.save_files!(save_files_params, rich_content_params, delete_missing: false) if contract&.degraded?

    owner.save_files!(save_files_params, rich_content_params)
  end

  private
    def perform_under_contract
      # Snapshot of what was alive before this save. Explicit deletions target
      # the snapshot the client edited — files created by this very request
      # can never be swept up by a clear-all sent alongside them.
      preexisting_files = owner.alive_product_files.to_a

      file_id_mappings = {}
      if contract.submitted?(:files)
        # The collection was actually submitted: apply creates/updates as
        # before, but `delete_missing: false` — under the contract, a file
        # missing from the payload is "no statement", not "delete me".
        file_id_mappings = owner.save_files!(updated_file_params(params[:files]), rich_content_params, delete_missing: false)
      end
      # else: absent or [] means "this request isn't about files" (Rule 1) —
      # there is nothing to create or update, and nothing gets deleted.

      files_to_delete =
        if contract.cleared?(:files)
          preexisting_files
        else
          ids = contract.deleted_ids(:files)
          ids.any? ? preexisting_files.select { ids.include?(_1.external_id) } : []
        end
      return file_id_mappings if files_to_delete.empty?

      # An id that is both kept in the payload and listed in deleted_ids is
      # contradictory; the explicit, revision-gated deletion wins — it is the
      # operation the client had to positively state.
      files_to_delete.each { _1.mark_deleted unless _1.deleted? }
      owner.cached_alive_product_files = nil
      owner.link&.enqueue_index_update_for(["filetypes"])
      file_id_mappings
    end

    def updated_file_params(all_file_params)
      all_file_params = all_file_params.is_a?(Array) ? all_file_params : all_file_params.values
      all_file_params.each do |file_params|
        file_params[:filetype] = "link" if file_params.delete(:extension) == "URL"
        if file_params.key?(:name)
          file_params[:display_name] ||= file_params[:name]
          file_params.delete(:name)
        end

        if file_params.key?(:file_name)
          file_params[:display_name] ||= file_params[:file_name]
          file_params.delete(:file_name)
        end
        # Hash#except! is missing on ActionController::Parameters (editor PUT),
        # and v2 JSON uses string keys. delete works for Hash, HWIA, and Parameters.
        UNWRITABLE_SERIALIZED_FILE_KEYS.each do |key|
          file_params.delete(key)
          file_params.delete(key.to_s)
        end
      end
    end
end
