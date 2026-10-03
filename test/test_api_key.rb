# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "net/http"

require_relative "workflow_dir"
require File.join(ALFRED_WORKFLOW_DIR, "deepl-key.rb")
require File.join(ALFRED_WORKFLOW_DIR, "deepl-api.rb")

# Every value here is synthetic. The 1Password CLI is replaced by a small
# script on PATH, and the keychain lookup by a stub, so nothing real is read
# and nothing is sent: new_request only builds a request.
class TestApiKey < Minitest::Test
  SYNTHETIC = "00000000-0000-0000-0000-000000000000:fx"
  REFERENCE = "op://Synthetic Vault/Synthetic Item/credential"
  SERVICE = "synthetic-deepl-service"

  def setup
    DeepLKey.forget
    @dir = Dir.mktmpdir
    @path = ENV["PATH"]
    @locations = DeepLKey::OP_LOCATIONS
    # Keep a real `op` installed on this Mac out of the picture.
    replace_const(:OP_LOCATIONS, [])
    ENV["PATH"] = "#{@dir}:/usr/bin:/bin"
  end

  def teardown
    ENV["PATH"] = @path
    replace_const(:OP_LOCATIONS, @locations)
    DeepLKey.forget
    FileUtils.rm_rf(@dir)
  end

  def replace_const(name, value)
    DeepLKey.send(:remove_const, name)
    DeepLKey.const_set(name, value)
  end

  def fake_op(body)
    path = File.join(@dir, "op")
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
  end

  # Replaces DeepLKey.run for one block. Written out rather than using
  # minitest/mock, which newer minitest no longer ships.
  def with_run(fake)
    original = DeepLKey.method(:run)
    DeepLKey.define_singleton_method(:run) { |argv| fake.call(argv) }
    yield
  ensure
    DeepLKey.define_singleton_method(:run, original)
  end

  def status(ok)
    Struct.new(:success?).new(ok)
  end

  # The message, checked to carry neither the value nor the reference: a
  # reference names the vault and item, and the message is shown on screen.
  def error_for(setting)
    DeepLKey.resolve(setting)
    flunk "expected an error for a #{setting.split(':').first} setting"
  rescue DeepLKey::Error => e
    refute_includes e.message, SYNTHETIC
    refute_includes e.message, "Synthetic"
    refute_includes e.message, SERVICE
    e.message
  end

  # --- the original form ------------------------------------------------------

  def test_a_plain_key_is_used_as_is
    assert_equal SYNTHETIC, DeepLKey.resolve("  #{SYNTHETIC}  ")
  end

  def test_an_empty_setting_says_so
    assert_match(/not set/, error_for(""))
  end

  # --- 1Password ---------------------------------------------------------------

  def test_a_1password_reference_is_read_with_op
    fake_op(%(if [ "$1" = read ] && [ "$2" = "#{REFERENCE}" ]; then echo "#{SYNTHETIC}"; else exit 1; fi))
    assert_equal SYNTHETIC, DeepLKey.resolve(REFERENCE)
  end

  def test_a_reference_with_spaces_reaches_op_as_one_argument
    fake_op(%(if [ "$#" = 2 ] && [ "$2" = "#{REFERENCE}" ]; then echo "#{SYNTHETIC}"; else exit 1; fi))
    assert_equal SYNTHETIC, DeepLKey.resolve(REFERENCE)
  end

  def test_op_is_found_outside_path
    fake_op(%(echo "#{SYNTHETIC}"))
    ENV["PATH"] = "/usr/bin:/bin"
    replace_const(:OP_LOCATIONS, [File.join(@dir, "op")])
    assert_equal SYNTHETIC, DeepLKey.resolve(REFERENCE)
  end

  def test_op_missing
    assert_match(/1Password CLI \(op\) was not found/, error_for(REFERENCE))
  end

  def test_op_not_signed_in
    fake_op(%(echo "[ERROR] 2026/10/03 You are not currently signed in. Synthetic detail" >&2; exit 1))
    message = error_for(REFERENCE)
    assert_match(/not signed in/, message)
    refute_includes message, "[ERROR]"   # nothing from op's own output
  end

  def test_unknown_item
    fake_op(%(echo "[ERROR] could not read secret 'Synthetic Item'" >&2; exit 1))
    message = error_for(REFERENCE)
    assert_match(/could not be read from 1Password/, message)
    refute_includes message, "op://"
  end

  def test_an_empty_answer_is_an_error
    fake_op("exit 0")
    assert_match(/is empty/, error_for(REFERENCE))
  end

  def test_more_than_one_line_is_an_error
    fake_op(%(echo "#{SYNTHETIC}"; echo "#{SYNTHETIC}"))
    assert_match(/more than one line/, error_for(REFERENCE))
  end

  def test_op_is_given_up_on_after_the_timeout
    fake_op("sleep 5")
    replace_const(:TIMEOUT_SEC, 1)
    assert_match(/did not answer/, error_for(REFERENCE))
  ensure
    replace_const(:TIMEOUT_SEC, 60)
  end

  def test_op_is_asked_once_per_run
    counter = File.join(@dir, "calls")
    fake_op(%(echo x >> "#{counter}"; echo "#{SYNTHETIC}"))
    3.times { DeepLKey.resolve(REFERENCE) }
    assert_equal 1, File.readlines(counter).size
  end

  # --- keychain ------------------------------------------------------------------

  def test_a_keychain_reference
    calls = []
    with_run(->(argv) { calls << argv; ["#{SYNTHETIC}\n", "", status(true)] }) do
      assert_equal SYNTHETIC, DeepLKey.resolve("keychain:#{SERVICE}")
    end
    assert_equal [["/usr/bin/security", "find-generic-password", "-s", SERVICE, "-w"]], calls
  end

  def test_a_missing_keychain_item
    with_run(->(_argv) { ["", "item not found", status(false)] }) do
      assert_match(/could not be read from the keychain/, error_for("keychain:#{SERVICE}"))
    end
  end

  def test_keychain_without_a_name
    assert_match(/no item name/, error_for("keychain:"))
  end

  # --- what reaches DeepL ------------------------------------------------------

  def test_the_request_carries_the_key_read_through_the_reference
    fake_op(%(echo "#{SYNTHETIC}"))
    uri, req = DeepL.new_request(Net::HTTP::Get, REFERENCE, "/v2/usage")
    assert_equal "DeepL-Auth-Key #{SYNTHETIC}", req["Authorization"]
    # The endpoint follows the key that was read, not the reference.
    assert_equal "api-free.deepl.com", uri.host
  end

  def test_an_unreadable_reference_never_becomes_a_request
    built = nil
    assert_raises(DeepLKey::Error) do
      built = DeepL.new_request(Net::HTTP::Get, REFERENCE, "/v2/usage")
    end
    assert_nil built
  end

  def test_a_plain_key_still_reaches_deepl_unchanged
    _uri, req = DeepL.new_request(Net::HTTP::Get, SYNTHETIC, "/v2/usage")
    assert_equal "DeepL-Auth-Key #{SYNTHETIC}", req["Authorization"]
  end
end
