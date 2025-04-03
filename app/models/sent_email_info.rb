# frozen_string_literal: true

class SentEmailInfo < ApplicationRecord
  validates_presence_of :key

  def self.key_exists?(key)
    where(key:).exists?
  end

  def self.set_key!(key)
    record = new
    record.key = key
    begin
      record.save!
    rescue ActiveRecord::RecordNotUnique
      nil
    end
  end

  def self.mailer_key_digest(mailer_class, mailer_method, *args)
    mail_key = "#{mailer_class}.#{mailer_method}#{args}"
    Digest::SHA1.hexdigest(mail_key)
  end

  def self.mailer_exists?(mailer_class, mailer_method, *args)
    digest = mailer_key_digest(mailer_class, mailer_method, *args)
    key_exists?(digest)
  end

  def self.ensure_mailer_uniqueness(mailer_class, mailer_method, *args, &block)
    digest = mailer_key_digest(mailer_class, mailer_method, *args)
    if !key_exists?(digest) && set_key!(digest)
      yield
    end
  end
end
