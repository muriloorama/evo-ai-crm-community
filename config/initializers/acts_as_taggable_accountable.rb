# Multi-account scoping for the acts_as_taggable_on gem.
#
# The `tags` table gained `account_id NOT NULL` in the Fase 1 migration, but
# ActsAsTaggableOn::Tag is declared inside the gem and does not include our
# Accountable concern — so labels/tag creation would either skip the default
# scope (fail-open) or explode with NOT NULL violations. Patching the class
# here keeps the fix outside the gem itself.
#
# Taggings (the join rows) inherit the tenant from the tag, so they do not
# need their own column; default_scope on Tag already prevents cross-account
# leakage through the tagger/taggable side.
Rails.application.config.to_prepare do
  if defined?(ActsAsTaggableOn::Tag) && !ActsAsTaggableOn::Tag.include?(Accountable)
    ActsAsTaggableOn::Tag.include(Accountable)
  end
end
