module Current
  thread_mattr_accessor :user
  thread_mattr_accessor :account
  thread_mattr_accessor :account_id
  thread_mattr_accessor :account_number
  thread_mattr_accessor :accounts
  thread_mattr_accessor :super_admin
  thread_mattr_accessor :executed_by
  thread_mattr_accessor :contact
  thread_mattr_accessor :api_access_token
  thread_mattr_accessor :bearer_token
  thread_mattr_accessor :service_authenticated
  thread_mattr_accessor :authentication_method
  thread_mattr_accessor :evo_auth_validation_cache
  thread_mattr_accessor :evo_permission_cache
  thread_mattr_accessor :evo_role_key

  def self.reset
    Current.user = nil
    Current.account = nil
    Current.account_id = nil
    Current.account_number = nil
    Current.accounts = nil
    Current.super_admin = nil
    Current.executed_by = nil
    Current.contact = nil
    Current.api_access_token = nil
    Current.bearer_token = nil
    Current.service_authenticated = nil
    Current.authentication_method = nil
    Current.evo_auth_validation_cache = nil
    Current.evo_permission_cache = nil
    Current.evo_role_key = nil
  end

  def self.super_admin?
    !!super_admin
  end
end
