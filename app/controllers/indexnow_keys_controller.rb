# frozen_string_literal: true

# Serves the IndexNow key verification file at /{key}.txt so search engines
# can validate ownership of submitted URLs (https://www.indexnow.org/documentation).
class IndexnowKeysController < ApplicationController
  def show
    key = GlobalConfig.get("INDEXNOW_KEY")

    if key.present? && ActiveSupport::SecurityUtils.secure_compare(params[:key].to_s, key)
      render plain: key
    else
      head :not_found
    end
  end
end
