# frozen_string_literal: true

class SaveFilesService
  delegate :product_files, to: :owner
  attr_reader :owner, :params, :rich_content_params

  def self.perform(*args)
    new(*args).perform
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
  def initialize(owner, params, rich_content_params = [])
    @owner = owner
    @params = params
    @rich_content_params = rich_content_params
  end

  def perform
    params[:files] = [] unless params.key?(:files)

    save_files_params = updated_file_params(params[:files])
    owner.save_files!(save_files_params, rich_content_params)
  end

  private
    def updated_file_params(all_file_params)
      all_file_params = all_file_params.is_a?(Array) ? all_file_params : all_file_params.values
      all_file_params.each do |file_params|
        file_params[:filetype] = "link" if file_params.delete(:extension) == "URL"
      end
    end
end
