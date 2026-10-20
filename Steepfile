# frozen_string_literal: true

target :consumer do
  configure_code_diagnostics Steep::Diagnostic::Ruby.strict
  signature "sig"
  check "test/types/consumer.rb", "test/types/invalid.rb"
end
