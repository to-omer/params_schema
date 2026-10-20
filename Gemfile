# frozen_string_literal: true

source "https://rubygems.org"
gemspec

group :test do
  gem "activerecord", ">= 8.0", "< 8.2"
  gem "minitest", "~> 6.0"
  gem "minitest-mock", "~> 5.27"
  gem "rack-test", "~> 2.2"
  gem "rake", "~> 13.4"
  gem "rspec-core", "~> 3.13", require: false
  gem "rspec-expectations", "~> 3.13", require: false
  gem "sqlite3", "~> 2.0"
end

group :development do
  # YARD's legacy parser loader requires IRB, no longer a default gem in Ruby 4.
  gem "irb", "~> 1.0", require: false
  gem "rbs", "~> 4.2.0", require: false
  gem "rubocop-minitest", "~> 0.41", require: false
  gem "rubocop-rails-omakase", "~> 1.1", require: false
  gem "steep", "~> 2.1.0", require: false
  gem "yard", "~> 0.9.45", require: false
end
