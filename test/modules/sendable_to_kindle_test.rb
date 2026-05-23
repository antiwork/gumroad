# frozen_string_literal: true

require "test_helper"

class SendableToKindleTest < ActiveSupport::TestCase
  self.described_class = SendableToKindle


  context_ SendableToKindle do
  context_ "#send_to_kindle" do
      before do
        @product_file = create(:product_file)
      end

  test "raises an error if the kindle email is invalid" do
        expect { @product_file.send_to_kindle("example@example.org") }.to raise_error(ArgumentError).with_message("Please enter a valid Kindle email address")
        expect { @product_file.send_to_kindle("EXAMPLE123.-23[]@KINDLE.COM") }.to raise_error(ArgumentError).with_message("Please enter a valid Kindle email address")
        expect { @product_file.send_to_kindle(".a12@KINDLE.COM") }.to raise_error(ArgumentError).with_message("Please enter a valid Kindle email address")
        expect { @product_file.send_to_kindle("example..23@KINDLE.COM") }.to raise_error(ArgumentError).with_message("Please enter a valid Kindle email address")
        expect { @product_file.send_to_kindle("example..@KINDLE.COM") }.to raise_error(ArgumentError).with_message("Please enter a valid Kindle email address")
        expect { @product_file.send_to_kindle("\"example.23\"@KINDLE.COM") }.to raise_error(ArgumentError).with_message("Please enter a valid Kindle email address")
        expect { @product_file.send_to_kindle("example123456789example123456789example123456789example123456789example123456789example123456789example123456789example123456789example123456789example123456789example123456789example123456789example123456789example123456789example123456789example123456789@KINDLE.COM") }.to raise_error(ArgumentError).with_message("Please enter a valid Kindle email address")
      end

  test "does not raise an error if the kindle email is valid" do
        expect { @product_file.send_to_kindle("example@kindle.com") }.not_to raise_error(ArgumentError)
        expect { @product_file.send_to_kindle("ExAmple123@KINDLE.com") }.not_to raise_error(ArgumentError)
        expect { @product_file.send_to_kindle("ExAmple.123@KINDLE.com") }.not_to raise_error(ArgumentError)
        expect { @product_file.send_to_kindle("ExAmple_123@KINDLE.com") }.not_to raise_error(ArgumentError)
        expect { @product_file.send_to_kindle("ExAmple__123@KINDLE.com") }.not_to raise_error(ArgumentError)
        expect { @product_file.send_to_kindle("ExAmple-123@KINDLE.com") }.not_to raise_error(ArgumentError)
        expect { @product_file.send_to_kindle("ExAmple--123@KINDLE.com") }.not_to raise_error(ArgumentError)
      end
    end
  end
end
