# frozen_string_literal: true

class MigrateEsIndicesDocumentType < ActiveRecord::Migration[6.1]
  # Original migration: https://github.com/antiwork/gumroad/blob/main/db/migrate/20210219002017_migrate_es_indices_document_type.rb

  def up
    return if Rails.env.production?
    DevTools.delete_all_indices_and_reindex_all
  end
end
