# frozen_string_literal: true

# Regenerates the fixtures credentials_test.go reads: a credentials file ActiveSupport encrypts,
# what GlobalConfig's credentials fallback returns for each name, and Marshal's length prefixes.
# The IV is random, so the encrypted file changes on every run; the values do not.
#
#   RBENV_VERSION=3.4.3 ruby go_web/internal/credentials/testdata/credentials_fixtures.rb

gem "activesupport", "8.1.3.1"

require "json"
require "tmpdir"
require "active_support"
require "active_support/encrypted_configuration"

DIR = __dir__
KEY = "0123456789abcdef0123456789abcdef"

YAML_SOURCE = <<~YAML
  secret_key_base: abc123
  obfuscate_ids_cipher_key: "quoted: value"
  obfuscate_ids_numeric_cipher_key: 123456789
  hex_like: 123e4567
  single_quoted: 'it''s'
  blank_value:
  tilde_value: ~
  stripe:
    endpoint_secret: whsec_test
    nested:
      deep: deeper
  sendgrid_gr_creators_webhook_public_key: |
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE
    -----END PUBLIC KEY-----
  folded: >
    one
    two
  shared: &shared shared-value
  aliased: *shared
  repeated: first
  repeated: last
  defaults: &defaults
    secret: from-defaults
    only_defaults: defaults-only
  others: &others
    secret: from-others
  merged_after_key:
    secret: own
    <<: *defaults
  merged_before_key:
    <<: *defaults
    secret: own
  merged_list:
    <<: [*others, *defaults]
  quoted_merge_key:
    "<<": literal
YAML

NAMES = %w[
  SECRET_KEY_BASE OBFUSCATE_IDS_CIPHER_KEY OBFUSCATE_IDS_NUMERIC_CIPHER_KEY HEX_LIKE SINGLE_QUOTED
  BLANK_VALUE TILDE_VALUE STRIPE__ENDPOINT_SECRET STRIPE__NESTED__DEEP STRIPE STRIPE__MISSING
  MISSING SENDGRID_GR_CREATORS_WEBHOOK_PUBLIC_KEY FOLDED ALIASED REPEATED
  MERGED_AFTER_KEY__SECRET MERGED_AFTER_KEY__ONLY_DEFAULTS MERGED_BEFORE_KEY__SECRET
  MERGED_LIST__SECRET MERGED_LIST__ONLY_DEFAULTS QUOTED_MERGE_KEY__SECRET
]

encrypted = File.join(DIR, "test.yml.enc")
File.delete(encrypted) if File.exist?(encrypted)
Dir.mktmpdir do |tmp|
  key_path = File.join(tmp, "production.key")
  File.write(key_path, KEY)
  config = ActiveSupport::EncryptedConfiguration.new(config_path: encrypted, key_path:, env_key: "UNSET_TEST_MASTER_KEY", raise_if_missing_key: true)
  config.write(YAML_SOURCE)

  # GlobalConfig.fetch_from_credentials, then the String the Go lookup has to return.
  lookups = NAMES.to_h do |name|
    value = config.dig(*name.downcase.split("__").map(&:to_sym))
    [name, value.is_a?(Hash) || value.nil? ? nil : value.to_s]
  end
  File.write(File.join(DIR, "credentials.json"), JSON.pretty_generate({ key: KEY, lookups: }) + "\n")
end

# Everything before the bytes of a UTF-8 String of each length; the encoding ivar follows them.
ENCODING_IVAR = "\x06:\x06ET".b
lengths = [0, 1, 116, 117, 122, 123, 255, 256, 65_535, 65_536, 16_777_216].to_h do |n|
  dumped = Marshal.dump("x" * n)
  raise "unexpected Marshal tail" unless dumped.end_with?(ENCODING_IVAR)
  [n.to_s, dumped.byteslice(0, dumped.bytesize - n - ENCODING_IVAR.bytesize).unpack1("H*")]
end
File.write(File.join(DIR, "marshal_lengths.json"), JSON.pretty_generate(lengths) + "\n")
