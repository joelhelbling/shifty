require "bundler/setup"

require "simplecov"
SimpleCov.start

require "rspec/given"
require "pry"
require "stringio"

require "shifty"

module StderrCapture
  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  # Shifty's deprecation warnings are emitted under Ruby's :deprecated
  # warning category, which is disabled by default; toggle it to observe.
  def with_deprecation_warnings(enabled: true)
    original = Warning[:deprecated]
    Warning[:deprecated] = enabled
    yield
  ensure
    Warning[:deprecated] = original
  end
end

RSpec.configure do |config|
  config.include StderrCapture

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.raise_errors_for_deprecations!
end
