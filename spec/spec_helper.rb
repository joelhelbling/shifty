require 'bundler/setup'

require 'simplecov'
SimpleCov.start

require 'rspec/its'
require 'rspec/given'
require 'pry'

require 'shifty'

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # should we use should?
  config.expect_with :rspec do |c|
    c.syntax = [:should, :expect]
  end

  config.mock_with :rspec do |c|
    c.syntax = [:should, :expect]
  end
end
