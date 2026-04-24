## Multi-account (multi-tenant) row-level scoping.
#
# Include this in every model whose table has an `account_id` column
# (see the `AddAccountIdToDataTables` migration for the authoritative list).
#
# Behavior:
#   * `default_scope` filters to `Current.account_id` when it is set.
#   * Super admins (`Current.super_admin?`) bypass the scope entirely and see
#     rows across every account — this powers the admin panel and cross-tenant
#     debugging. Any such access should be logged by the caller.
#   * When no account context is set (e.g. boot-time rake tasks, specs without
#     `with_account`, or background jobs that forget to populate `Current`),
#     the scope falls through to `all`. This is a deliberate fail-open choice
#     to avoid silently hiding data in system contexts — callers that need a
#     specific account must set `Current.account_id` or use `with_account`.
#   * `account_id` is auto-populated from `Current.account_id` on create so
#     application code rarely needs to pass it explicitly.
module Accountable
  extend ActiveSupport::Concern

  included do
    belongs_to :account_record, class_name: 'Account', foreign_key: :account_id, optional: true if defined?(::Account)

    default_scope -> {
      # Note: we deliberately DO NOT bypass for super_admin here. Even platform
      # operators see only the workspace they have switched into — cross-account
      # operations must be performed inside an explicit `Accountable.as_super_admin`
      # block (used by the admin panel controllers). Without this, super_admins
      # would silently see leads from every tenant in every screen.
      next all if Current.account_id.blank?

      where(arel_table[:account_id].eq(Current.account_id))
    }

    before_validation :assign_account_id_from_current, on: :create
  end

  class_methods do
    # Available on any class that includes Accountable (e.g. `Contact.with_account`).
    def with_account(account_id, &block)
      Accountable.with_account(account_id, &block)
    end

    def as_super_admin(&block)
      Accountable.as_super_admin(&block)
    end
  end

  # Module-level helpers so callers don't need a model class to set context:
  #
  #   Accountable.with_account(account_id) do
  #     Contact.where(...) # scoped to account_id
  #     Conversation.create!(...) # account_id auto-assigned
  #   end
  def self.with_account(account_id)
    previous_id = Current.account_id
    previous_super = Current.super_admin
    Current.account_id = account_id
    Current.super_admin = false
    yield
  ensure
    Current.account_id = previous_id
    Current.super_admin = previous_super
  end

  # Temporarily enables super_admin mode (bypassing default_scope) inside the
  # block. Intended for admin panel controllers and explicit cross-tenant
  # scripts — never for user-triggered requests.
  def self.as_super_admin
    previous = Current.super_admin
    Current.super_admin = true
    yield
  ensure
    Current.super_admin = previous
  end

  private

  def assign_account_id_from_current
    return if account_id.present?
    return if Current.account_id.blank?

    self.account_id = Current.account_id
  end
end
