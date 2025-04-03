# frozen_string_literal: true

class SetElasticsearchIndicesMappingsAsStrictlyNonDynamic < ActiveRecord::Migration[6.1]
  def up
    [Link, Balance, Purchase, Installment, ConfirmedFollowerEvent].each do |model|
      EsClient.indices.put_mapping(index: model.index_name, body: { dynamic: :strict })
    end
  end

  def down
    EsClient.indices.put_mapping(index: Link.index_name, body: { dynamic: true })
    [Balance, Purchase, Installment, ConfirmedFollowerEvent].each do |model|
      EsClient.indices.put_mapping(index: model.index_name, body: { dynamic: false })
    end
  end
end
