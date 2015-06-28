Encoding.default_internal = 'UTF-8'

if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    add_filter '/spec/'
  end
  SimpleCov.at_exit do
    SimpleCov.result.format!
  end
end

require 'i18n'
I18n.config.enforce_available_locales = true

FLAPJACK_ENV    = ENV["FLAPJACK_ENV"] || 'test'
FLAPJACK_ROOT   = File.join(File.dirname(__FILE__), '..')
FLAPJACK_CONFIG = File.join(FLAPJACK_ROOT, 'etc', 'flapjack_test_config.toml')
ENV['RACK_ENV'] = ENV["FLAPJACK_ENV"]

require 'bundler'
Bundler.require(:default, :test)

ActiveSupport.use_standard_json_time_format = true
ActiveSupport.time_precision = 0

require 'webmock/rspec'
WebMock.disable_net_connect!

$:.unshift(File.dirname(__FILE__) + '/../lib')
require 'flapjack'
require 'flapjack/patches'
require 'flapjack/configuration'

# Requires supporting files with custom matchers and macros, etc,
# in ./support/ and its subdirectories.
Dir["#{File.dirname(__FILE__)}/support/**/*.rb"].each {|f| require f}

require 'mail'
::Mail.defaults do
  delivery_method :test
end

require 'flapjack/redis_proxy'

require './spec/service_consumers/fixture_data.rb'

# This file was generated by the `rspec --init` command. Conventionally, all
# specs live under a `spec` directory, which RSpec adds to the `$LOAD_PATH`.
# Require this file using `require "spec_helper"` to ensure that it is only
# loaded once.
#
# See http://rubydoc.info/gems/rspec-core/RSpec/Core/Configuration
RSpec.configure do |config|
  config.run_all_when_everything_filtered = true
  config.filter_run :focus

  # Run specs in random order to surface order dependencies. If you find an
  # order dependency and want to debug it, you can fix the order by providing
  # the seed, which is printed after each run.
  #     --seed 1234
  config.order = 'random'

  # # TODO clear these up, where possible
  # config.warnings = true

  unless (ENV.keys & ['SHOW_LOGGER_ALL', 'SHOW_LOGGER_ERRORS']).empty?
    config.instance_variable_set('@formatters', [])
    config.add_formatter(:documentation)
  end

  config.before(:suite) do
    cfg = Flapjack::Configuration.new
    $redis_options = cfg.load(FLAPJACK_CONFIG) ?
                     cfg.for_redis :
                     {:db => 14, :driver => :ruby}
  end

  config.around(:each, :redis => true) do |example|
    Flapjack::RedisProxy.config = $redis_options
    Zermelo.redis = Flapjack.redis
    Flapjack.redis.flushdb
    example.run
    Flapjack.redis.quit
  end

  config.around(:each, :logger => true) do |example|
    MockLogger.configure_log('flapjack')
    Flapjack.logger = MockLogger.new
    example.run

    if ENV['SHOW_LOGGER_ALL']
      puts Flapjack.logger.messages.compact.join("\n")
    end

    if ENV['SHOW_LOGGER_ERRORS']
      puts Flapjack.logger.errors.compact.join("\n")
    end

    Flapjack.logger.errors.clear
  end

  config.after(:each, :time => true) do
    Delorean.back_to_the_present
  end

  config.after(:each) do
    WebMock.reset!
  end

  config.include JsonSpec::Helpers, :sinatra => true
  config.include Factory, :redis => true
  config.include ErbViewHelper, :erb_view => true
  config.include Rack::Test::Methods, :sinatra => true
  config.include FixtureData, :pact_fixture => true
end
