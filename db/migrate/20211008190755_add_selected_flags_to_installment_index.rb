# frozen_string_literal: true

class AddSelectedFlagsToInstallmentIndex < ActiveRecord::Migration[6.1]
  def up
    EsClient.indices.put_mapping(
      index: Installment.index_name,
      body: {
        properties: {
          selected_flags: { type: "keyword" },
        }
      }
    )
  end
end
