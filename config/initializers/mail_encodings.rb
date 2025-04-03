# frozen_string_literal: true

# TODO (vishal): Remove this initializer when we start relying on a Rails
# version that includes this change https://github.com/rails/rails/pull/46650.
#
# Following code overrides the Mail::Encodings::QuoatedPritable class
# as per https://github.com/mikel/mail/pull/1210.
# See https://github.com/gumroad/web/pull/24988 for more information.
module Mail
  module Encodings
    class QuotedPrintable < SevenBit
      def self.decode(str)
        ::Mail::Utilities.to_lf ::Mail::Utilities.to_crlf(str).gsub(/(?:=0D=0A|=0D|=0A)\r\n/, "\r\n").unpack("M*").first
      end

      def self.encode(str)
        ::Mail::Utilities.to_crlf [::Mail::Utilities.to_lf(str)].pack("M")
      end
    end
  end
end
