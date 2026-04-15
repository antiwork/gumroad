# frozen_string_literal: true

module ExternalId
  extend ActiveSupport::Concern

  def external_id
    ObfuscateIds.encrypt(id)
  end

  def external_id_numeric
    ObfuscateIds.encrypt_numeric(id)
  end

  class_methods do
    def to_external_id(id)
      ObfuscateIds.encrypt(id)
    end

    def from_external_id(external_id)
      ObfuscateIds.decrypt(external_id)
    end

    def find_by_external_id(external_id)
      find_by(id: from_external_id(external_id))
    end

    def find_by_external_id!(external_id)
      find_by!(id: from_external_id(external_id))
    end

    def find_by_external_id_numeric(id)
      find_by(id: ObfuscateIds.decrypt_numeric(id))
    end

    def find_by_external_id_numeric!(id)
      find_by!(id: ObfuscateIds.decrypt_numeric(id))
    end

    def by_external_ids(external_ids)
      where(id: Array.wrap(external_ids).map { from_external_id(it) })
    end

    def external_id?(id_or_external_id)
      raise ArgumentError, "value can't be blank" if id_or_external_id.blank?

      id_or_external_id.to_i.to_s != id_or_external_id
    end
  end
end
