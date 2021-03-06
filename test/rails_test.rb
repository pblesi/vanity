require "test/test_helper"

class UseVanityController < ActionController::Base
  attr_accessor :current_user

  def index
    render :text=>ab_test(:pie_or_cake)
  end

  def js
    ab_test(:pie_or_cake)
    render :inline => "<%= vanity_js -%>"
  end
end

# Pages accessible to everyone, e.g. sign in, community search.
class UseVanityControllerTest < ActionController::TestCase
  tests UseVanityController

  def setup
    super
    metric :sugar_high
    new_ab_test :pie_or_cake do
      metrics :sugar_high
    end
    UseVanityController.class_eval do
      use_vanity :current_user
    end
    if ::Rails.respond_to?(:application) # Rails 3 configuration
      ::Rails.application.config.session_options[:domain] = '.foo.bar'
    end
  end

  def test_render_js_for_tests
    Vanity.playground.use_js!
    get :js
    assert_match /script.*e=pie_or_cake.*script/m, @response.body
  end

  def test_chooses_sets_alternatives_for_rails_tests
    experiment(:pie_or_cake).chooses(true)
    get :index
    assert_equal 'true', @response.body

    experiment(:pie_or_cake).chooses(false)
    get :index
    assert_equal 'false', @response.body
  end

  def test_adds_participant_to_experiment
    get :index
    assert_equal 1, experiment(:pie_or_cake).alternatives.map(&:participants).sum
  end

  def test_does_not_add_invalid_participant_to_experiment
    @request.user_agent = "Googlebot/2.1 ( http://www.google.com/bot.html)"
    get :index
    assert_equal 0, experiment(:pie_or_cake).alternatives.map(&:participants).sum
  end

  def test_vanity_cookie_is_persistent
    get :index
    cookie = @response["Set-Cookie"].to_s
    assert_match /vanity_id=[a-f0-9]{32};/, cookie
    expires = cookie[/expires=(.*)(;|$)/, 1]
    assert expires
    assert_in_delta Time.parse(expires), Time.now + 1.month, 1.day
  end

  def test_vanity_cookie_default_id
    get :index
    assert cookies["vanity_id"] =~ /^[a-f0-9]{32}$/
  end

  def test_vanity_cookie_retains_id
    @request.cookies["vanity_id"] = "from_last_time"
    get :index
    # Rails 2 funkieness: if the cookie isn't explicitly set in the response,
    # cookies[] is empty. Just make sure it's not re-set.
    assert_equal rails3? ? "from_last_time" : nil,  cookies["vanity_id"]
  end

  def test_vanity_identity_set_from_cookie
    @request.cookies["vanity_id"] = "from_last_time"
    get :index
    assert_equal "from_last_time", @controller.send(:vanity_identity)
  end

  def test_vanity_identity_set_from_user
    @controller.current_user = mock("user", :id=>"user_id")
    get :index
    assert_equal "user_id", @controller.send(:vanity_identity)
  end

  def test_vanity_identity_with_no_user_model
    UseVanityController.class_eval do
      use_vanity nil
    end
    @controller.current_user = Object.new
    get :index
    assert cookies["vanity_id"] =~ /^[a-f0-9]{32}$/
  end

  def test_vanity_identity_set_with_block
    UseVanityController.class_eval do
      attr_accessor :project_id
      use_vanity { |controller| controller.project_id }
    end
    @controller.project_id = "576"
    get :index
    assert_equal "576", @controller.send(:vanity_identity)
  end

  def test_vanity_identity_set_with_indentity_paramater
    get :index, :_identity => "id_from_params"
    assert_equal "id_from_params", @controller.send(:vanity_identity)
  end

  def test_vanity_identity_prefers_block_over_symbol
    UseVanityController.class_eval do
      attr_accessor :project_id
      use_vanity(:current_user) { |controller| controller.project_id }
    end
    @controller.project_id = "576"
    @controller.current_user = stub(:id=>"user_id")

    get :index
    assert_equal "576", @controller.send(:vanity_identity)
  end

    def test_vanity_identity_prefers_parameter_over_cookie
    @request.cookies['vanity_id'] = "old_id"
    get :index, :_identity => "id_from_params"
    assert_equal "id_from_params", @controller.send(:vanity_identity)
    assert cookies['vanity_id'], "id_from_params"
  end

  def test_vanity_identity_prefers_cookie_over_object
    @request.cookies['vanity_id'] = "from_last_time"
    @controller.current_user = stub(:id=>"user_id")
    get :index
    assert_equal "from_last_time", @controller.send(:vanity_identity)
  end

  # query parameter filter

  def test_redirects_and_loses_vanity_query_parameter
    get :index, :foo=>"bar", :_vanity=>"567"
    assert_redirected_to "/use_vanity?foo=bar"
  end

  def test_sets_choices_from_vanity_query_parameter
    first = experiment(:pie_or_cake).alternatives.first
    fingerprint = experiment(:pie_or_cake).fingerprint(first)
    10.times do
      @controller = nil ; setup_controller_request_and_response
      get :index, :_vanity => fingerprint
      assert_equal experiment(:pie_or_cake).choose, experiment(:pie_or_cake).alternatives.first
      assert experiment(:pie_or_cake).showing?(first)
    end
  end

  def test_does_nothing_with_vanity_query_parameter_for_posts
    experiment(:pie_or_cake).chooses(experiment(:pie_or_cake).alternatives.last.value)
    first = experiment(:pie_or_cake).alternatives.first
    fingerprint = experiment(:pie_or_cake).fingerprint(first)
    post :index, :foo => "bar", :_vanity => fingerprint
    assert_response :success
    assert !experiment(:pie_or_cake).showing?(first)
  end

  def test_track_param_tracks_a_metric
    get :index, :_identity => "123", :_track => "sugar_high"
    assert_equal experiment(:pie_or_cake).alternatives[0].converted, 1
  end

  def test_cookie_domain_from_rails_configuration
    get :index
    assert_match /domain=.foo.bar/, @response["Set-Cookie"] if ::Rails.respond_to?(:application)
  end

  def teardown
    super
    if !rails3?
      UseVanityController.send(:filter_chain).clear
    end
  end

end

class VanityMailer < ActionMailer::Base
  include Vanity::Rails::Helpers
  include ActionView::Helpers::AssetTagHelper
  include ActionView::Helpers::TagHelper

  def ab_test_subject(user, forced_outcome=true)
    use_vanity_mailer user
    experiment(:pie_or_cake).chooses(forced_outcome)

    if defined?(Rails::Railtie)
      mail :subject =>ab_test(:pie_or_cake).to_s, :body => ""
    else
      subject ab_test(:pie_or_cake).to_s
      body ""
    end
  end

  def ab_test_content(user)
    use_vanity_mailer user

    if defined?(Rails::Railtie)
      mail do |format|
        format.html { render :text=>view_context.vanity_tracking_image(Vanity.context.vanity_identity, :open, :host => "127.0.0.1:3000") }
      end
    else
      body vanity_tracking_image(Vanity.context.vanity_identity, :open, :host => "127.0.0.1:3000")
    end
  end
end

class UseVanityMailerTest < ActionMailer::TestCase
  tests VanityMailer

  def setup
    super
    metric :sugar_high
    new_ab_test :pie_or_cake do
      metrics :sugar_high
    end
  end

  def test_js_enabled_still_adds_participant
    Vanity.playground.use_js!
    rails3? ? VanityMailer.ab_test_subject(nil, true) : VanityMailer.deliver_ab_test_subject(nil, true)

    alts = experiment(:pie_or_cake).alternatives
    assert_equal 1, alts.map(&:participants).sum
  end

  def test_returns_different_alternatives
    email = rails3? ? VanityMailer.ab_test_subject(nil, true) : VanityMailer.deliver_ab_test_subject(nil, true)
    assert_equal 'true', email.subject

    email = rails3? ? VanityMailer.ab_test_subject(nil, false) : VanityMailer.deliver_ab_test_subject(nil, false)
    assert_equal 'false', email.subject
  end

  def test_tracking_image_is_rendered
    email = rails3? ? VanityMailer.ab_test_content(nil) : VanityMailer.deliver_ab_test_content(nil)
    assert email.body =~ /<img/
    assert email.body =~ /_identity=/
  end
end

class LoadPathAndConnectionConfigurationTest < Test::Unit::TestCase

  def test_load_path
    assert_equal File.expand_path("tmp/experiments"), load_rails("", <<-RB)
$stdout << Vanity.playground.load_path
    RB
  end

  def test_settable_load_path
    assert_equal File.expand_path("tmp/predictions"), load_rails(%Q{\nVanity.playground.load_path = "predictions"\n}, <<-RB)
$stdout << Vanity.playground.load_path
    RB
  end

  def test_absolute_load_path
    Dir.mktmpdir do |dir|
      assert_equal dir, load_rails(%Q{\nVanity.playground.load_path = "#{dir}"\n}, <<-RB)
$stdout << Vanity.playground.load_path
      RB
    end
  end

  if ENV['DB'] == 'redis'
    def test_default_connection
      assert_equal "redis://127.0.0.1:6379/0", load_rails("", <<-RB)
$stdout << Vanity.playground.connection
      RB
    end

    def test_connection_from_string
      assert_equal "redis://192.168.1.1:6379/5", load_rails(%Q{\nVanity.playground.establish_connection "redis://192.168.1.1:6379/5"\n}, <<-RB)
$stdout << Vanity.playground.connection
      RB
    end

    def test_connection_from_yaml
      FileUtils.mkpath "tmp/config"
      @original_env = ENV["RAILS_ENV"]
      ENV["RAILS_ENV"] = "production"
      File.open("tmp/config/vanity.yml", "w") do |io|
        io.write <<-YML
production:
  adapter: redis
  host: somehost
  database: 15
        YML
      end
      assert_equal "redis://somehost:6379/15", load_rails("", <<-RB)
$stdout << Vanity.playground.connection
      RB
    ensure
      ENV["RAILS_ENV"] = @original_env
      File.unlink "tmp/config/vanity.yml"
    end

    def test_connection_from_yaml_url
      FileUtils.mkpath "tmp/config"
      @original_env = ENV["RAILS_ENV"]
      ENV["RAILS_ENV"] = "production"
      File.open("tmp/config/vanity.yml", "w") do |io|
        io.write <<-YML
production: redis://somehost/15
        YML
      end
      assert_equal "redis://somehost:6379/15", load_rails("", <<-RB)
$stdout << Vanity.playground.connection
      RB
    ensure
      ENV["RAILS_ENV"] = @original_env
      File.unlink "tmp/config/vanity.yml"
    end

    def test_connection_from_yaml_with_erb
      FileUtils.mkpath "tmp/config"
      @original_env = ENV["RAILS_ENV"]
      ENV["RAILS_ENV"] = "production"
      # Pass storage URL through environment like heroku does
      @original_redis_url = ENV["REDIS_URL"]
      ENV["REDIS_URL"] = "redis://somehost:6379/15"
      File.open("tmp/config/vanity.yml", "w") do |io|
        io.write <<-YML
production: <%= ENV['REDIS_URL'] %>
        YML
      end
      assert_equal "redis://somehost:6379/15", load_rails("", <<-RB)
$stdout << Vanity.playground.connection
      RB
    ensure
      ENV["RAILS_ENV"] = @original_env
      ENV["REDIS_URL"] = @original_redis_url
      File.unlink "tmp/config/vanity.yml"
    end

    def test_connection_from_redis_yml
      FileUtils.mkpath "tmp/config"
      yml = File.open("tmp/config/redis.yml", "w")
      yml << "production: internal.local:6379\n"
      yml.flush
      assert_equal "redis://internal.local:6379/0", load_rails("", <<-RB)
$stdout << Vanity.playground.connection
      RB
    ensure
      File.unlink yml.path
    end
  end

  if ENV['DB'] == 'mongo'
    def test_mongo_connection_from_yaml
      FileUtils.mkpath "tmp/config"
      File.open("tmp/config/vanity.yml", "w") do |io|
        io.write <<-YML
mongodb:
  adapter: mongodb
  host: localhost
  port: 27017
  database: vanity_test
        YML
      end

      assert_equal "mongodb://localhost:27017/vanity_test", load_rails("", <<-RB, "mongodb")
$stdout << Vanity.playground.connection
      RB
    ensure
      File.unlink "tmp/config/vanity.yml"
    end

    unless ENV['CI'] == 'true' #TODO this doesn't get tested on CI
      def test_mongodb_replica_set_connection
        FileUtils.mkpath "tmp/config"
        File.open("tmp/config/vanity.yml", "w") do |io|
          io.write <<-YML
mongodb:
  adapter: mongodb
  hosts:
    - localhost
  port: 27017
  database: vanity_test
          YML
        end

        assert_equal "mongodb://localhost:27017/vanity_test", load_rails("", <<-RB, "mongodb")
$stdout << Vanity.playground.connection
        RB

        assert_equal "Mongo::ReplSetConnection", load_rails("", <<-RB, "mongodb")
$stdout << Vanity.playground.connection.mongo.class
        RB
      ensure
        File.unlink "tmp/config/vanity.yml"
      end
    end
  end

  def test_connection_from_yaml_missing
    FileUtils.mkpath "tmp/config"
    File.open("tmp/config/vanity.yml", "w") do |io|
      io.write <<-YML
production:
  adapter: redis
      YML
    end

     assert_equal "No configuration for development", load_rails("\nbegin\n", <<-RB, "development")
rescue RuntimeError => e
  $stdout << e.message
end
      RB
  ensure
    File.unlink "tmp/config/vanity.yml"
  end

  def test_collection_from_vanity_yaml
    FileUtils.mkpath "tmp/config"
    File.open("tmp/config/vanity.yml", "w") do |io|
      io.write <<-YML
production:
  collecting: false
  adapter: mock
      YML
    end
    assert_equal "false", load_rails("", <<-RB)
$stdout << Vanity.playground.collecting?
    RB
  ensure
    File.unlink "tmp/config/vanity.yml"
  end

  def test_collection_true_in_production_by_default
    assert_equal "true", load_rails("", <<-RB)
$stdout << Vanity.playground.collecting?
    RB
  end

  def test_collection_false_in_production_when_configured
    assert_equal "false", load_rails("\nVanity.playground.collecting = false\n", <<-RB)
$stdout << Vanity.playground.collecting?
    RB
  end

  def test_collection_true_in_development_by_default
    assert_equal "true", load_rails("", <<-RB, "development")
$stdout << Vanity.playground.collecting?
    RB
  end

  def test_collection_true_in_development_when_configured
    assert_equal "true", load_rails("\nVanity.playground.collecting = true\n", <<-RB, "development")
$stdout << Vanity.playground.collecting?
    RB
  end

  def test_collection_false_after_test!
    assert_equal "false", load_rails("", <<-RB)
Vanity.playground.test!
$stdout << Vanity.playground.collecting?
    RB
  end

  def test_playground_loads_if_connected
    assert_equal "{}", load_rails("", <<-RB)
$stdout << Vanity.playground.instance_variable_get(:@experiments).inspect
    RB
  end

  def test_playground_does_not_load_if_not_connected
    ENV['VANITY_DISABLED'] = '1'
    assert_equal "nil", load_rails("", <<-RB)
$stdout << Vanity.playground.instance_variable_get(:@experiments).inspect
    RB
    ENV['VANITY_DISABLED'] = nil
  end

  def load_rails(before_initialize, after_initialize, env="production")
    tmp = Tempfile.open("test.rb")
    begin
      code_setup = <<-RB
$:.delete_if { |path| path[/gems\\/vanity-\\d/] }
$:.unshift File.expand_path("../lib")
RAILS_ROOT = File.expand_path(".")
      RB
      code = code_setup
      code += defined?(Rails::Railtie) ? load_rails_3_or_4(env) : load_rails_2(env)
      code += %Q{\nrequire "vanity"\n}
      code += before_initialize
      code += defined?(Rails::Railtie) ? initialize_rails_3_or_4 : initialize_rails_2
      code += after_initialize
      tmp.write code
      tmp.flush
      Dir.chdir "tmp" do
        open("| ruby #{tmp.path}").read
      end
    ensure
      tmp.close!
    end
  end

  def load_rails_2(env)
    <<-RB
RAILS_ENV = ENV['RACK_ENV'] = "#{env}"
require "initializer"
require "active_support"
Rails.configuration = Rails::Configuration.new
initializer = Rails::Initializer.new(Rails.configuration)
initializer.check_gem_dependencies
    RB
  end

  def load_rails_3_or_4(env)
    <<-RB
ENV['BUNDLE_GEMFILE'] ||= "#{ENV['BUNDLE_GEMFILE']}"
require 'bundler/setup' if File.exists?(ENV['BUNDLE_GEMFILE'])
ENV['RAILS_ENV'] = ENV['RACK_ENV'] = "#{env}"
require "active_model/railtie"
require "action_controller/railtie"

Bundler.require(:default)

module Foo
  class Application < Rails::Application
    config.active_support.deprecation = :notify
    config.eager_load = #{env == "production"} if Rails::Application.respond_to?(:eager_load!)
    ActiveSupport::Deprecation.silenced = true if ActiveSupport::Deprecation.respond_to?(:silenced) && ENV['CI']
  end
end
    RB
  end

  def initialize_rails_2
    <<-RB
initializer.after_initialize
    RB
  end

  def initialize_rails_3_or_4
    <<-RB
Foo::Application.initialize!
    RB
  end

end
