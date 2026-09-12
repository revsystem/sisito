require_relative 'boot'

require 'rails/all'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Sisito
  class Application < Rails::Application
    # 全環境共通のフレームワークデフォルト。他の config.* 設定より前に置くこと
    # (load_defaults は一部の明示設定を上書きするため)。Rails 8系への移行に向けて
    # 段階的に引き上げる (7.0 -> 7.1 -> 7.2 -> 8.0 -> 8.1)。
    config.load_defaults 7.2

    # Settings in config/environments/* take precedence over those specified here.
    # Application configuration should go into files in config/initializers
    # -- all .rb files in that directory are automatically loaded.

    # Rails 7.2では明示的にSprocketsを有効にする必要がある
    config.add_autoload_paths_to_load_path = true

    # アセットパイプラインの設定
    config.javascript_path = "javascript"

    # Active Recordのタイムゾーン設定
    config.active_record.default_timezone = :local
    config.active_record.schema_format = :ruby
  end
end
