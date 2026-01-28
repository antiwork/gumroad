# frozen_string_literal: true

class AddSelectedFlagsToInstallmentIndex < ActiveRecord::Migration[4.2]
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
