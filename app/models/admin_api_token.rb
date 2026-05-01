# frozen_string_literal: true

class AdminApiToken < ApplicationRecord
  EXTERNAL_ID_LENGTH = 21
  PLAINTEXT_TOKEN_LENGTH = 43
  TOKEN_ALPHABET = "_-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

  belongs_to :actor_user, class_name: "User"
  has_many :admin_api_audit_logs

  validates :external_id, presence: true, uniqueness: true
  validates :token_hash, presence: true, uniqueness: true
  validates :actor_user, presence: true

  before_validation :generate_external_id, on: :create

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def self.mint!(actor_user_id:, expires_at: nil)
    plaintext_token = generate_plaintext_token
    create!(actor_user_id:, expires_at:, token_hash: hash_token(plaintext_token))

    plaintext_token
  end

  def self.seed_legacy_admin_token!
    legacy_token = GlobalConfig.get("INTERNAL_ADMIN_API_TOKEN").to_s
    return nil if legacy_token.blank?

    find_or_create_by!(token_hash: hash_token(legacy_token)) do |admin_api_token|
      admin_api_token.actor_user_id = GUMROAD_ADMIN_ID
    end
  end

  def self.authenticate(plaintext_token)
    return nil if plaintext_token.blank?

    token_hash = hash_token(plaintext_token)
    admin_api_token = find_by(token_hash:)
    return nil if admin_api_token.blank?
    return nil unless ActiveSupport::SecurityUtils.secure_compare(admin_api_token.token_hash, token_hash)
    return nil unless admin_api_token.active?

    admin_api_token
  end

  def self.hash_token(plaintext_token)
    Digest::SHA256.hexdigest(plaintext_token.to_s)
  end

  def self.generate_plaintext_token
    generate_token(PLAINTEXT_TOKEN_LENGTH)
  end

  def self.generate_token(length)
    Array.new(length) { TOKEN_ALPHABET[SecureRandom.random_number(TOKEN_ALPHABET.length)] }.join
  end

  def self.legacy_admin_token
    where(actor_user_id: GUMROAD_ADMIN_ID).order(:id).first
  end

  def active?
    revoked_at.blank? && !expired?
  end

  def legacy_admin_token?
    legacy_admin_token = self.class.legacy_admin_token
    legacy_admin_token.present? && id == legacy_admin_token.id
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def record_used!
    update_column(:last_used_at, Time.current)
  end

  private
    def generate_external_id
      return if external_id.present?

      loop do
        self.external_id = self.class.generate_token(EXTERNAL_ID_LENGTH)
        break unless self.class.exists?(external_id:)
      end
    end
end
