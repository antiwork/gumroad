# frozen_string_literal: true

class PublicFilePresenter
  include CdnUrlHelper

  def initialize(public_file:)
    @public_file = public_file
  end

  def props
    {
      id: public_file.public_id,
      name: public_file.display_name,
      extension: public_file.file_type&.upcase,
      file_size: public_file.file_size,
      url: public_file.file.attached? ? cdn_url_for(public_file.file.blob.url) : nil,
      status: { type: "saved" },
    }
  end

  private
    attr_reader :public_file
end
