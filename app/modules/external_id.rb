# frozen_string_literal: true

module ExternalId
  def self.included(base)
    base.extend(ClassMethods)
  end

  def external_id
    ObfuscateIds.encrypt(id)
  end

  def external_id_numeric
    ObfuscateIds.encrypt_numeric(id)
  end

  module ClassMethods
    def find_by_external_id(id)
      find_by(id: ObfuscateIds.decrypt(id))
    end

    def find_by_external_id!(id)
      find_by!(id: ObfuscateIds.decrypt(id))
    end

    def find_by_external_id_numeric(id)
      find_by(id: ObfuscateIds.decrypt_numeric(id))
    end

    def find_by_external_id_numeric!(id)
      find_by!(id: ObfuscateIds.decrypt_numeric(id))
    end

    def by_external_ids(ids)
      where(id: Array.wrap(ids).map { |id| ObfuscateIds.decrypt(id) })
    end
  end
end
