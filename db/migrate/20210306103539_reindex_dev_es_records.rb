# frozen_string_literal: true

class ReindexDevEsRecords < ActiveRecord::Migration[6.1]
  # For developer convenience, we reindex everything since we're now using a new ES server, with no data.

  def up
    return if Rails.env.production?

    if EsClient.info["version"]["number"].starts_with?("6.")
      error_message = "=" * 50
      error_message += "\n\nYou're running an older docker-compose (with an older ES server), you need to restart it now (e.g. `make local`), and try again.\n\n"
      error_message += "=" * 50
      raise error_message
    end

    DevTools.delete_all_indices_and_reindex_all
  end
end
