# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path(__dir__)

require 'chronic_duration'
require 'active_record'
require 'settingslogic'
require 'sidekiq'
require 'raven'

module Hpr
  class << self
    def init
      init_sentry
      init_sidekiq
      connect_database
    end

    def init_sidekiq
      redis_url = { url: ENV['HPR_REDIS_URL'] || 'redis://localhost:6379/2' }

      Sidekiq.configure_server do |config|
        config.redis = redis_url
      end

      Sidekiq.configure_client do |config|
        config.redis = redis_url
      end

      Sidekiq.default_worker_options = { 'backtrace' => true }

      Sidekiq::Logging.logger = Logger.new(File.join(Hpr.root, 'logs/sidekiq.log'))
      Sidekiq::Logging.logger.level = Logger::DEBUG unless producton?
    end

    def connect_database
      ActiveRecord::Base.establish_connection(
        adapter: 'sqlite3',
        database: Hpr.db_file
      )
    end

    def init_sentry
      return unless Hpr::Configuration.sentry_enable?

      Raven.configure do |config|
        config.dsn = Hpr::Configuration.sentry.dns
        config.async = lambda { |event| Hpr::SentryWorker.perform_async(event) }
        config.environments = %w[development production]
        config.current_environment = ENV['HPR_ENV'] || 'development'
        config.logger = Logger.new(File.join(Hpr.root, 'logs/sentry.log'))
        config.release = Hpr::VERSION
        config.tags = { running_env: running_env }
        config.tags[:git_commit] = git_rev if git_rev
      end

      Raven.user_context username: hostname
    end

    def running_env
      ENV.fetch('HPR_RUNNING', 'script')
    end

    def hostname
      @hostname ||= `hostname`.strip
    end

    def git_rev
      @git_rev ||= `git rev-parse HEAD`.strip if File.directory?(File.join(root, '.git'))
    end

    def producton?
      env == 'production'
    end

    def env
      ENV['HPR_ENV']
    end

    def root
      File.expand_path('..', __dir__)
    end

    def db_file
      File.join(root, 'repositories', 'hpr.sqlite')
    end
  end

  class Configuration < Settingslogic
    source "#{Hpr.root}/config/hpr.yml" if File.file?("#{Hpr.root}/config/hpr.yml")

    self['repository_path'] = File.join(Hpr.root, 'repositories', gitlab.group_name)

    def self.schedule_in_seconds
      case schedule_in
      when String
        ChronicDuration.parse schedule_in.sub('.', ' ')
      else
        schedule_in.to_i
      end
    end

    def self.basic_auth?
      basic_auth.enable
    end

    def self.sentry_enable?
      sentry.report
    end
  end
end

require 'hpr/version'
require 'hpr/ext/git_mixin'
require 'hpr/error'
require 'hpr/helper'
require 'hpr/repository'
require 'hpr/client'
require 'hpr/web'
require 'hpr/worker'

# init
Hpr.init