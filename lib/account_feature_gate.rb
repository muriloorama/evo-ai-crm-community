# frozen_string_literal: true

# AccountFeatureGate — CRM-side mirror of evo-auth-service's FeatureGate.
#
# In this service `Current.account` is a hash (built by EvoAuthConcern from
# the auth-service token-validation response). It carries `features` and
# `settings` keys when the auth response includes them — so callers can
# gate functionality without making a second hop to auth.
#
# Defaults live in `config/account_defaults.yml` and are intentionally
# wide-open. An empty `features={}` / `settings={}` (every existing tenant
# today, including Oramatech) keeps full access, exactly like before this
# system was introduced.
#
# Keys accept dotted paths or shorthand:
#   - `"features.pipelines"`, `"channels.whatsapp_cloud"`, `"ai.enabled"`
#   - `"pipelines"` shorthand → `features.pipelines`
#   - `"whatsapp_cloud"` shorthand → `channels.whatsapp_cloud`
#   - `"max_inboxes"` for `limit` → `limits.max_inboxes`
module AccountFeatureGate
  DEFAULTS_PATH = Rails.root.join('config', 'account_defaults.yml').freeze

  class << self
    def allows?(account, key)
      path = normalize_path(key)
      value = read_path(account, path)
      return true if value.nil?
      !!value
    end

    def limit(account, key)
      path = normalize_limit_path(key)
      value = read_settings_path(account, path)
      return value if value.is_a?(Integer)
      return nil if value.nil? || value == ''

      Integer(value, exception: false)
    end

    def under_limit?(account, key, current_count)
      cap = limit(account, key)
      cap.nil? || current_count < cap
    end

    def snapshot(account)
      deep_merge_indifferent(defaults, overrides(account))
    end

    def defaults
      @defaults ||= load_defaults
    end

    def reset_defaults!
      @defaults = nil
    end

    private

    def load_defaults
      return {} unless File.exist?(DEFAULTS_PATH)
      raw = YAML.safe_load_file(DEFAULTS_PATH, permitted_classes: [Symbol]) || {}
      raw.deep_stringify_keys
    end

    def overrides(account)
      feats = read_account_value(account, :features) || {}
      sets  = read_account_value(account, :settings) || {}
      feats = feats.deep_stringify_keys if feats.respond_to?(:deep_stringify_keys)
      sets  = sets.deep_stringify_keys  if sets.respond_to?(:deep_stringify_keys)

      merged = {}
      merged['features'] = feats['features'] if feats['features'].is_a?(Hash)
      merged['ai']       = feats['ai']       if feats['ai'].is_a?(Hash)
      merged['channels'] = feats['channels'] if feats['channels'].is_a?(Hash)
      merged['limits']   = sets['limits']    if sets['limits'].is_a?(Hash)
      merged
    end

    def read_account_value(account, key)
      return nil if account.nil?

      if account.respond_to?(key)
        account.public_send(key)
      elsif account.is_a?(Hash)
        account[key.to_s] || account[key]
      end
    end

    def read_path(account, path)
      ovr = overrides(account).dig(*path)
      return ovr unless ovr.nil?
      defaults.dig(*path)
    end

    def read_settings_path(account, path)
      sets = read_account_value(account, :settings) || {}
      sets = sets.deep_stringify_keys if sets.respond_to?(:deep_stringify_keys)
      ovr = sets.dig(*path)
      return ovr unless ovr.nil?
      defaults.dig(*path)
    end

    def normalize_path(key)
      parts = key.to_s.split('.')
      return parts if parts.length >= 2

      bare = parts[0]
      case bare
      when 'enabled' then ['ai', 'enabled']
      when 'whatsapp_cloud', 'whatsapp_uazapi', 'whatsapp_evolution',
           'instagram', 'facebook', 'email', 'webhook', 'api'
        ['channels', bare]
      else
        ['features', bare]
      end
    end

    def normalize_limit_path(key)
      parts = key.to_s.split('.')
      return parts if parts.length >= 2

      bare = parts[0]
      return ['ai', 'max_bots'] if bare == 'max_bots'
      ['limits', bare]
    end

    def deep_merge_indifferent(a, b)
      merger = proc do |_k, v1, v2|
        if v1.is_a?(Hash) && v2.is_a?(Hash)
          v1.merge(v2, &merger)
        else
          v2.nil? ? v1 : v2
        end
      end
      a.deep_stringify_keys.merge(b.deep_stringify_keys, &merger)
    end
  end
end
